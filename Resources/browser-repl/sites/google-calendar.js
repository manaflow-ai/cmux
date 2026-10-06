// sites.googleCalendar: events read from the Calendar web app in a background
// tab (each event element carries data-eventid and a full spoken description
// for screen readers), and events created through Calendar's documented
// event template link after a confirmed draft.
(function (root) {
  "use strict";
  const S = root.CmuxBrowserRepl && root.CmuxBrowserRepl.sites;
  if (!S) return;
  const { URLSearchParams } = root.CmuxBrowserRepl.core;
  const SIGN_IN = [/^https:\/\/accounts\.google\.com\//, /^https:\/\/workspace\.google\.com\//, /\/calendar\/about/];
  const VIEWS = ["day", "week", "month", "agenda"];

  function readEvents(arg) {
    const clean = (s) => (s || "").replace(/\s+/g, " ").trim();
    const out = new Map();
    for (const el of document.querySelectorAll("[data-eventid]")) {
      const id = el.getAttribute("data-eventid");
      if (!id || out.has(id)) continue;
      // The description a screen reader speaks: "10:00am to 11:00am, Title, Person, Location: X, September 30, 2026".
      const hidden = [...el.querySelectorAll("div, span")].map((e) => clean(e.textContent)).filter((s) => s.includes(",")).sort((a, b) => b.length - a.length)[0];
      const description = clean(el.getAttribute("aria-label")) || hidden || clean(el.innerText);
      const parts = description.split(", ");
      const timeLike = /^(all day|\d{1,2}(:\d{2})?\s*(am|pm)?\b.*|\d{1,2}:\d{2}.*)$/i;
      const title = parts.length > 1 && timeLike.test(parts[0]) ? parts[1] : parts[0];
      const location = (parts.find((p) => /^Location: /.test(p)) || "").replace(/^Location: /, "") || undefined;
      out.set(id, { id, title, when: timeLike.test(parts[0]) ? parts[0] : undefined, location, description, url: `${arg.base}r/eventedit/${id}` });
      if (out.size >= arg.limit) break;
    }
    return [...out.values()];
  }

  const pad = (n) => String(n).padStart(2, "0");
  const ymd = (d) => `${d.getUTCFullYear()}${pad(d.getUTCMonth() + 1)}${pad(d.getUTCDate())}`;
  const stamp = (d) => `${ymd(d)}T${pad(d.getUTCHours())}${pad(d.getUTCMinutes())}${pad(d.getUTCSeconds())}Z`;
  const toDate = (v, name) => {
    const d = v instanceof Date ? v : new Date(v);
    if (isNaN(d.getTime())) throw new S.SiteError("invalid", `googleCalendar.create: ${name}: expected a date, got ${JSON.stringify(v)}`);
    return d;
  };

  // The event form, checked against the draft right before Save: the title,
  // the start and end as the form shows them (dates and times in the
  // event's time zone: the draft's timeZone, else this Mac's, which the
  // browser and Calendar's default use), and the guests (the organizer, who
  // Calendar lists once there are guests, aside). Fields are read through
  // locators, in the agent's isolated world.
  const MONTHS = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"];
  function zonedParts(d, timeZone) {
    const f = new Intl.DateTimeFormat("en-US", { timeZone, year: "numeric", month: "numeric", day: "numeric", hour: "numeric", minute: "numeric", hourCycle: "h23" });
    const o = {};
    for (const part of f.formatToParts(d)) o[part.type] = part.value;
    return { y: Number(o.year), m: Number(o.month), d: Number(o.day), h: Number(o.hour) % 24, min: Number(o.minute) };
  }
  // "Oct 1, 2026", "Thursday, October 1", "2026-10-01", or a numeric date
  // that reads only one way ("10/13/2026", "13/10/2026", "5/5/2026"). Calendar's
  // date format is a user setting the form does not name, so a numeric date
  // whose month and day could be either way round ("10/1/2026": October 1
  // or January 10) is not accepted as any date.
  function dateShows(text, p) {
    const s = String(text || "").toLowerCase();
    const nums = (s.match(/\d+/g) || []).map(Number);
    const year = nums.find((n) => n >= 1000);
    if (year !== undefined && year !== p.y) return false;
    const small = nums.filter((n) => n < 1000);
    const named = MONTHS.findIndex((m) => new RegExp(`\\b${m}`).test(s));
    if (named >= 0) return named + 1 === p.m && small.length === 1 && small[0] === p.d;
    if (small.length !== 2) return false;
    const [a, b] = small;
    // Year first is always year, month, day.
    if (/^\D*\d{4}\D/.test(s)) return a === p.m && b === p.d;
    if (a === b) return a === p.m && b === p.d;
    // Two readings when both could be a month.
    if (a <= 12 && b <= 12) return false;
    return (a === p.m && b === p.d) || (a === p.d && b === p.m);
  }
  // "5:00pm", "5pm", "17:00".
  function timeShows(text, p) {
    const m = /^\s*(\d{1,2})(?::(\d{2}))?\s*(a|p)?\.?\s*m?\.?\s*$/i.exec(String(text || ""));
    if (!m) return false;
    let h = Number(m[1]);
    if (m[3]) {
      if (h < 1 || h > 12) return false;
      h = (h % 12) + (m[3].toLowerCase() === "p" ? 12 : 0);
    }
    return h === p.h && Number(m[2] || 0) === p.min;
  }
  async function fieldText(locator) {
    if (!(await locator.count())) return null;
    const one = locator.first();
    const tag = String(await one._read("tagName", undefined, { timeout: 2000 }, "tag name")).toLowerCase();
    return tag === "input" || tag === "textarea" ? one.inputValue({ timeout: 2000 }) : one.innerText({ timeout: 2000 });
  }
  // A drafted RRULE as the fields Calendar's recurrence menu can show:
  // FREQ, INTERVAL, COUNT or UNTIL, and BYDAY (weekdays; for MONTHLY one
  // ordinal weekday such as 3TH or -1FR) or BYMONTHDAY (MONTHLY, one day).
  // Anything else (BYMONTH, BYSETPOS, WKST, several rules, a repeated key)
  // returns null: the form's words could not show it, so it is refused.
  const RRULE_DAYS = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"];
  function parseRule(recurrence) {
    const text = String(recurrence).trim().replace(/^RRULE:/i, "");
    if (!text || /[\r\n]/.test(text)) return null;
    const rule = {};
    for (const part of text.split(";")) {
      const m = /^([A-Za-z]+)=([^=;]+)$/.exec(part.trim());
      if (!m) return null;
      const k = m[1].toUpperCase();
      if (k in rule || !["FREQ", "INTERVAL", "COUNT", "UNTIL", "BYDAY", "BYMONTHDAY"].includes(k)) return null;
      rule[k] = m[2].toUpperCase();
    }
    if (!["DAILY", "WEEKLY", "MONTHLY", "YEARLY"].includes(rule.FREQ)) return null;
    if (rule.INTERVAL !== undefined && !/^[1-9]\d*$/.test(rule.INTERVAL)) return null;
    if (rule.COUNT !== undefined && !/^[1-9]\d*$/.test(rule.COUNT)) return null;
    if (rule.UNTIL !== undefined && !/^\d{8}(T\d{6}Z?)?$/.test(rule.UNTIL)) return null;
    if (rule.COUNT !== undefined && rule.UNTIL !== undefined) return null;
    const out = { freq: rule.FREQ, every: Number(rule.INTERVAL || 1), count: rule.COUNT || null, until: rule.UNTIL || null, days: null, ordinal: null, monthDay: null };
    if (rule.BYDAY !== undefined) {
      if (rule.FREQ === "WEEKLY") {
        const days = rule.BYDAY.split(",");
        if (!days.every((d) => RRULE_DAYS.includes(d)) || new Set(days).size !== days.length) return null;
        out.days = days.map((d) => RRULE_DAYS.indexOf(d)).sort();
      } else if (rule.FREQ === "MONTHLY") {
        const m = /^([+-]?[1-5])(SU|MO|TU|WE|TH|FR|SA)$/.exec(rule.BYDAY);
        if (!m || m[1] === "-2" || m[1] === "-3" || m[1] === "-4" || m[1] === "-5" || rule.BYMONTHDAY !== undefined) return null;
        out.ordinal = { n: Number(m[1]), day: RRULE_DAYS.indexOf(m[2]) };
      } else return null;
    }
    if (rule.BYMONTHDAY !== undefined) {
      if (rule.FREQ !== "MONTHLY" || !/^([1-9]|[12]\d|3[01])$/.test(rule.BYMONTHDAY)) return null;
      out.monthDay = Number(rule.BYMONTHDAY);
    }
    return out;
  }
  // Whether Calendar's recurrence menu text ("Does not repeat", "Weekly on
  // Thursday", "Every 2 weeks on Monday, Thursday, 5 times", "Monthly on
  // day 15", "Monthly on the third Thursday", "Annually on October 1",
  // "Monthly on day 1, until Dec 31, 2026") repeats exactly as the drafted
  // RRULE: frequency and interval, the weekdays or day of the month (the
  // start's when the rule names none, as Calendar fills them in), the exact
  // COUNT and UNTIL date. `start` is the start's parts in the event's zone.
  const WEEKDAY_NAMES = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"];
  const ORDINALS = { 1: "first", 2: "second", 3: "third", 4: "fourth", 5: "fifth", "-1": "last" };
  function repeatsAs(raw, recurrence, start, zone) {
    const text = String(raw || "").trim().toLowerCase();
    if (!recurrence) return text === "does not repeat";
    if (text === "does not repeat") return false;
    const rule = parseRule(recurrence);
    if (!rule) return false;
    let rest = text;
    // The end: ", N times" or ", until <date>" (or neither).
    const count = /,\s*(\d+) times$/.exec(rest);
    const until = count ? null : /,?\s*until (.+)$/.exec(rest);
    if (count) rest = rest.slice(0, count.index);
    if (until) rest = rest.slice(0, until.index);
    if ((rule.count || null) !== (count ? count[1] : null)) return false;
    if (!!rule.until !== !!until) return false;
    if (rule.until) {
      const u = rule.until;
      const p = /Z$/.test(u) ? zonedParts(new Date(Date.UTC(+u.slice(0, 4), +u.slice(4, 6) - 1, +u.slice(6, 8), +u.slice(9, 11), +u.slice(11, 13), +u.slice(13, 15))), zone) : { y: +u.slice(0, 4), m: +u.slice(4, 6), d: +u.slice(6, 8) };
      if (!dateShows(until[1], p)) return false;
    }
    rest = rest.trim();
    const weekdayOf = (p) => new Date(Date.UTC(p.y, p.m - 1, p.d)).getUTCDay();
    // "Every weekday (Monday to Friday)" is weekly on Monday to Friday.
    if (/^every weekday\b/.test(rest)) return rule.freq === "WEEKLY" && rule.every === 1 && rule.days !== null && rule.days.join() === "1,2,3,4,5";
    const unit = { DAILY: "day", WEEKLY: "week", MONTHLY: "month", YEARLY: "year" }[rule.freq];
    const head = rule.every > 1 ? new RegExp(`^every ${rule.every} ${unit}s\\b`) : { DAILY: /^(daily|every day)\b/, WEEKLY: /^weekly\b/, MONTHLY: /^monthly\b/, YEARLY: /^(annually|yearly)\b/ }[rule.freq];
    const h = head.exec(rest);
    if (!h) return false;
    const on = rest.slice(h[0].length).trim();
    if (rule.freq === "DAILY") return on === "";
    const sel = /^on (.+)$/.exec(on);
    if (!sel) return false;
    if (rule.freq === "WEEKLY") {
      const names = sel[1].split(/\s*(?:,|\band\b)\s*/).filter(Boolean);
      const shown = names.map((n) => WEEKDAY_NAMES.indexOf(n));
      if (shown.some((i) => i < 0) || new Set(shown).size !== shown.length) return false;
      const want = rule.days || [weekdayOf(start)];
      return shown.sort().join() === want.join();
    }
    if (rule.freq === "MONTHLY") {
      if (rule.ordinal) return sel[1] === `the ${ORDINALS[rule.ordinal.n]} ${WEEKDAY_NAMES[rule.ordinal.day]}`;
      return sel[1] === `day ${rule.monthDay || start.d}`;
    }
    // YEARLY: on the start's month and day.
    return dateShows(sel[1], { y: start.y, m: start.m, d: start.d });
  }
  // What the event form in `page` would save, for a commit's observe(): per
  // drafted field, the drafted value when the form shows it (dates and
  // times in the draft's time zone, the recurrence as Calendar words it),
  // else what the form shows; a field the form does not show is left out
  // (unverified). Guests are the addresses the form lists besides the
  // account's own.
  async function observeForm(page, draft, accountEmail) {
    const out = {};
    const norm = (v) => String(v || "").replace(/[​-‍⁠﻿]/g, "").replace(/\s+/g, " ").trim();
    const field = (label) => fieldText(page.locator(`[role="main"] [aria-label="${label}"]`));
    const title = await field("Title");
    if (title !== null) out.title = title.trim();
    const zone = draft.timeZone || new Intl.DateTimeFormat().resolvedOptions().timeZone;
    const startDate = new Date(draft.start);
    const endDate = new Date(draft.end);
    // All-day dates are calendar days (UTC in the template); the form shows
    // the last day, not the day after.
    const start = draft.allDay ? zonedParts(startDate, "UTC") : zonedParts(startDate, zone);
    const end = draft.allDay ? zonedParts(new Date(endDate.getTime() - 86400000), "UTC") : zonedParts(endDate, zone);
    const startDay = await field("Start date");
    const endDay = await field("End date");
    const startTime = await field("Start time");
    const endTime = await field("End time");
    // An all-day event's form shows no times.
    if (startDay !== null) out.allDay = !startTime && !endTime;
    const sameDay = start.y === end.y && start.m === end.m && start.d === end.d;
    // The end date is shown only when it differs from the start.
    const startShown = startDay !== null && dateShows(startDay, start) && (draft.allDay || timeShows(startTime, start));
    const endShown = (endDay === null ? sameDay : dateShows(endDay, end)) && (draft.allDay || timeShows(endTime, end));
    if (startDay !== null) out.start = startShown ? draft.start : `${startDay} ${startTime || ""}`.trim();
    if (startDay !== null) out.end = endShown ? draft.end : `${endDay || startDay} ${endTime || ""}`.trim();
    const location = await fieldText(page.locator('[role="main"] [aria-label="Location"], [role="main"] [aria-label="Add location"]'));
    if (location !== null) out.location = norm(location);
    const description = await fieldText(page.locator('[role="main"] [aria-label="Description"]'));
    if (description !== null) out.description = norm(description);
    const recurrence = await fieldText(page.locator('[role="main"] [aria-label="Recurrence"]'));
    if (recurrence !== null) out.recurrence = repeatsAs(norm(recurrence), draft.recurrence, start, zone) ? draft.recurrence : norm(recurrence);
    const listed = page.locator('[role="main"] [data-email]');
    const n = await listed.count();
    if (n < 200) {
      const shown = new Set();
      for (let i = 0; i < n; i++) shown.add(String((await listed.nth(i).getAttribute("data-email", { timeout: 2000 })) || "").trim().toLowerCase());
      shown.delete(String(accountEmail).toLowerCase());
      out.guests = [...shown];
    }
    return out;
  }

  S.register(
    "googleCalendar",
    (t) => {
      const base = (uid) => {
        const u = uid === undefined ? 0 : uid;
        if (!Number.isInteger(u) || u < 0) throw new S.SiteError("invalid", `googleCalendar: uid: expected a non-negative integer, got ${JSON.stringify(uid)}`);
        return `https://calendar.google.com/calendar/u/${u}/`;
      };
      return {
        // [{ id, title, when, location, description, url }] shown in a view.
        // Options: date (default today), view ("week" | "day" | "month" | "agenda"),
        // query (Calendar search instead of a view), limit (100), uid.
        async events(options = {}) {
          const view = options.view || "week";
          if (!VIEWS.includes(view)) throw new S.SiteError("invalid", `googleCalendar.events: view: expected ${VIEWS.join(", ")}, got ${JSON.stringify(view)}`);
          const d = options.date === undefined ? new Date(t.now()) : new Date(options.date);
          if (isNaN(d.getTime())) throw new S.SiteError("invalid", `googleCalendar.events: date: expected a date, got ${JSON.stringify(options.date)}`);
          const b = base(options.uid);
          const url = options.query ? `${b}r/search?q=${encodeURIComponent(options.query)}` : `${b}r/${view}/${d.getFullYear()}/${d.getMonth() + 1}/${d.getDate()}`;
          return t.withTab(url, async (page) => {
            t.assertSignedIn("googleCalendar.events", page, SIGN_IN);
            await t.waitIn(page, () => !!document.querySelector('[role="main"], [data-eventid]'), undefined, { signIn: SIGN_IN, name: "googleCalendar", what: "Google Calendar" });
            await t.sleep(300);
            return page.evaluate(readEvents, { base: b, limit: options.limit || 100 });
          });
        },
        // Draft an event: { title, start, end, allDay, description, location,
        // guests: [emails], timeZone, recurrence: "RRULE:...", uid }.
        // create(draftId, { confirm: true }) saves it (and sends invitations to guests).
        create(input, options) {
          return t.write("googleCalendar", "create", input, options, async (e) => {
            if (!e || typeof e !== "object" || !e.title) throw new S.SiteError("invalid", "googleCalendar.create: expected { title, start, end }");
            const start = toDate(e.start, "start");
            const end = e.end === undefined ? new Date(start.getTime() + (e.allDay ? 86400000 : 3600000)) : toDate(e.end, "end");
            if (end <= start) throw new S.SiteError("invalid", "googleCalendar.create: end must be after start");
            const guests = [].concat(e.guests || []).map(String);
            for (const g of guests) if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(g)) throw new S.SiteError("invalid", `googleCalendar.create: guests: ${JSON.stringify(g)} is not an email address`);
            const q = new URLSearchParams({ action: "TEMPLATE", text: String(e.title), dates: e.allDay ? `${ymd(start)}/${ymd(end)}` : `${stamp(start)}/${stamp(end)}` });
            if (e.description) q.set("details", String(e.description));
            if (e.location) q.set("location", String(e.location));
            if (guests.length) q.set("add", guests.join(","));
            if (e.timeZone) {
              try {
                new Intl.DateTimeFormat("en-US", { timeZone: String(e.timeZone) });
              } catch {
                throw new S.SiteError("invalid", `googleCalendar.create: timeZone: expected an IANA time zone, got ${JSON.stringify(e.timeZone)}`);
              }
              q.set("ctz", String(e.timeZone));
            }
            if (e.recurrence) {
              if (!parseRule(e.recurrence)) throw new S.SiteError("invalid", `googleCalendar.create: recurrence: expected one RRULE with FREQ (DAILY, WEEKLY, MONTHLY, YEARLY), INTERVAL, COUNT or UNTIL, and BYDAY or BYMONTHDAY as Calendar's repeat menu shows them; got ${JSON.stringify(e.recurrence)}`);
              q.set("recur", String(e.recurrence));
            }
            const uid = e.uid === undefined ? 0 : e.uid;
            base(uid);
            q.set("authuser", String(uid));
            const url = `https://calendar.google.com/calendar/render?${q}`;
            // The draft pins the account by Google's account id and email:
            // u/N is positional.
            const g = S.shared.google;
            const who = await g.accountAt(t, "googleCalendar.create", uid);
            const set = (list) => [...new Set((list || []).map((x) => String(x).trim().toLowerCase()))].sort();
            const norm = (v) => String(v || "").replace(/[​-‍⁠﻿]/g, "").replace(/\s+/g, " ").trim();
            return {
              category: guests.length ? "[9] create appointments; [14] sends invitations to guests" : "[9] create appointments",
              summary: `Create "${e.title}" ${e.allDay ? "all day" : ""} ${start.toISOString()} to ${end.toISOString()} as ${who.email} (u/${uid})${guests.length ? `, inviting ${guests.join(", ")}` : ""}`.replace(/\s+/g, " "),
              account: { account: uid, accountEmail: who.email, accountId: who.id },
              target: { guests },
              content: { title: String(e.title), start: start.toISOString(), end: end.toISOString(), allDay: !!e.allDay, description: e.description ? String(e.description) : "", location: e.location ? String(e.location) : "", timeZone: e.timeZone || null, recurrence: e.recurrence ? String(e.recurrence) : null },
              // The zone the form's times are read in (Calendar shows none).
              sent: ["timeZone"],
              canon: { guests: set, title: (v) => String(v).trim(), description: norm, location: norm, accountEmail: (v) => String(v).toLowerCase() },
              commit: (c) =>
                t.withTab(url, async (page) => {
                  t.assertSignedIn("googleCalendar.create", page, SIGN_IN);
                  const save = page.getByRole("button", { name: "Save", exact: true });
                  await save.first().waitFor({ timeout: 30000 });
                  // The account this event editor saves as and the event the
                  // form holds, read right before Save.
                  return c.write(
                    async () => ({ ...(await g.observeAccount(t, "googleCalendar.create", page, uid)), ...(await observeForm(page, c.intent, who.email)) }),
                    async (press) => {
                      await press();
                      // With guests, Save opens the invitation dialog, whose
                      // Send saves the event and emails them: the one Send
                      // in the dialog, pinned, after the form (guests
                      // included) and the account are read back again.
                      if (guests.length) {
                        const send = page.locator('[role="dialog"], [role="alertdialog"]').getByRole("button", { name: /^Send$/ });
                        const shown = await send.first().waitFor({ timeout: 8000 }).then(() => true, () => false);
                        if (shown) await press.next(send);
                      }
                      await t.waitIn(page, () => !/\/eventedit/.test(location.pathname) || /Event saved|Saved/.test(document.body.innerText), undefined, { signIn: SIGN_IN, name: "googleCalendar", timeout: 20000, what: "Calendar to save the event" });
                      return { status: "saved", title: String(e.title), start: start.toISOString(), end: end.toISOString() };
                    },
                    { submit: save.first() },
                  );
                }),
            };
          });
        },
      };
    },
    { summary: "Google Calendar events in a view or search; confirmed-draft event creation", writes: ["create"] },
  );
})(typeof globalThis !== "undefined" ? globalThis : this);
