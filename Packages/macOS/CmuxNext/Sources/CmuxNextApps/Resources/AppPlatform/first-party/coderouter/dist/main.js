// Built by cmux app pack from src/main.ts. Do not edit.
(() => {
  var __defProp = Object.defineProperty;
  var __returnValue = (v) => v;
  function __exportSetter(name, newValue) {
    this[name] = __returnValue.bind(null, newValue);
  }
  var __export = (target, all) => {
    for (var name in all)
      __defProp(target, name, {
        get: all[name],
        enumerable: true,
        configurable: true,
        set: __exportSetter.bind(all, name)
      });
  };
  var exports_main = {};
  __export(exports_main, {
    connectAccount: () => connectAccount,
    createKey: () => createKey2,
    cycleVariant: () => cycleVariant2,
    open: () => open,
    renderDashboard: () => renderDashboard,
    renderOnboarding: () => renderOnboarding,
    renderSection: () => renderSection,
    renderStatus: () => renderStatus,
    runTest: () => runTest2,
    startOnboarding: () => startOnboarding
  });
  var locale = "en";
  function setLocale(value) {
    locale = value && value.toLowerCase().startsWith("ja") ? "ja" : "en";
  }
  function t(key, english, vars) {
    const text = (locale === "ja" ? JA[key] : undefined) ?? english;
    return vars ? text.replace(/\{(\w+)\}/g, (m, name) => (name in vars) ? String(vars[name]) : m) : text;
  }
  var JA = {
    "account.active": "有効",
    "account.broken": "再サインインが必要",
    "account.cooling": "クールダウン中",
    "account.disabled": "無効",
    "account.expired": "期限切れ",
    "account.mine": "あなたが接続したアカウント",
    "account.refreshing": "更新中",
    "account.teammate": "チームメンバーが共有したアカウント",
    "accounts.empty": "アカウントはまだありません",
    "accounts.empty.body": "この Mac でプロバイダーの CLI にサインインするか、キーを追加してください。",
    "accounts.found": "この Mac で見つかったもの",
    "action.addKey": "キーで追加…",
    "action.back": "戻る",
    "action.connect": "接続",
    "action.continue": "続ける",
    "action.copy": "コピー",
    "action.createKey": "キーを作成",
    "action.done": "完了",
    "action.finish": "終了",
    "action.finishSetup": "設定を完了",
    "action.hide": "隠す",
    "action.makePrivate": "非公開にする",
    "action.open": "CodeRouter を開く",
    "action.openDashboard": "ダッシュボードを開く",
    "action.remove": "CodeRouter から削除…",
    "action.rescan": "もう一度確認",
    "action.retry": "再試行",
    "action.reviewSetup": "設定を見直す",
    "action.revoke": "キーを無効化…",
    "action.runTest": "テストを実行",
    "action.setUp": "CodeRouter を設定",
    "action.share": "共有",
    "action.shareAll": "すべて {team} と共有",
    "action.shareWithTeam": "チームと共有",
    "action.show": "表示",
    "action.signIn": "サインイン",
    "action.signInAgain": "再サインイン",
    "action.skip": "スキップ",
    "action.skipSetup": "設定をスキップ",
    "action.turnOff": "オフにする",
    "action.turnOn": "オンにする",
    "age.days": "{n} 日前",
    "age.hours": "{n} 時間前",
    "age.minutes": "{n} 分前",
    "age.never": "未使用",
    "age.now": "たった今",
    "checklist.left": "残り {n}",
    "checklist.title": "CodeRouter を設定",
    "command.nothingToConnect": "この Mac に新しく接続できるものはありません。",
    "detect.expired": "期限切れ",
    "detect.key": "キーあり",
    "detect.missing": "見つかりません",
    "detect.signedIn": "サインイン済み",
    "detect.unknown": "検出",
    "health.degraded": "低下",
    "health.down": "停止",
    "health.ok": "正常",
    "health.unknown": "不明",
    "key.created": "{label} を作成しました ({prefix}…)",
    "key.defaultLabel": "cmux キー",
    "key.placeholder": "キーの名前 (例: editor)",
    "key.revoked": "無効化済み",
    "key.tokens7d": "トークン (7 日)",
    "keys.empty": "キーはありません。キーがあれば、どのツールもチームの共有アカウントを使えます。",
    "notice.agentsOff": "エージェントは再びそれぞれのサインインを使います。",
    "notice.agentsOn": "cmux の新しいエージェントセッションは CodeRouter を使います。",
    "notice.connected": "{name} を接続しました。共有するまで非公開です。",
    "notice.connectHandedOff": "{name} の接続を cmux で完了してください。",
    "notice.copied": "コピーしました。クリップボードは 60 秒後に消去されます。",
    "notice.noPanes": "この cmux ビルドはアプリのペインをまだ開けません。サイドバーのチェックリストは「次の CodeRouter バリアント」で表示できます。",
    "notice.private": "あなただけの非公開になりました。",
    "notice.removed": "{label} を CodeRouter から削除しました。",
    "notice.shared": "チームと共有しました。",
    "onboarding.done": "CodeRouter の準備ができました",
    "onboarding.done.body": "エージェントとキーは、接続したアカウント間でフェイルオーバーします。",
    "onboarding.signIn": "CodeRouter を設定するには cmux にサインインしてください",
    "onboarding.signIn.body": "CodeRouter はあなたの cmux アカウントとチームとして動作します。",
    "problem.cancelled": "キャンセルしました",
    "problem.other": "問題が発生しました",
    "problem.scope": "権限が必要です",
    "problem.scope.body": "{op} を使うには、設定 > アプリ で CodeRouter を許可してください。",
    "problem.signedOut": "cmux にサインイン",
    "problem.signedOut.body": "CodeRouter はあなたの cmux アカウントとチームとして動作します。",
    "problem.unreachable": "CodeRouter に接続できません",
    "problem.unsupported": "この cmux ビルドでは使えません",
    "problem.unsupported.body": "このビルドには {op} 操作がまだありません。",
    "route.empty": "この API を提供するアカウントはまだありません。",
    "route.headroom": "CodeRouter は残り容量が最も多いアカウントを選び、同じならこの順に使います。",
    "route.messages": "Anthropic API",
    "route.ordered": "CodeRouter はこの順に試します。ドラッグで変更できます。",
    "route.responses": "OpenAI API",
    "scope.personal": "個人",
    "section.accounts": "アカウント",
    "section.accountsCount": "{total} 件中 {healthy} 件のアカウントが利用可能",
    "section.finishSetup": "設定を完了する",
    "section.keys": "API キー",
    "section.keysCount": "API キー {n} 件",
    "section.noAccounts": "接続済みのアカウントはありません",
    "section.routing": "フェイルオーバー順",
    "section.sharedCount": "{n} 件をチームと共有",
    "section.signIn.sub": "CodeRouter を使うために",
    "section.test": "テストリクエスト",
    "section.usage": "使用量",
    "state.connected": "接続済み",
    "state.loading": "読み込み中…",
    "status.agentsOff": "エージェントはそれぞれのサインインを使用",
    "status.agentsOn": "エージェントは CodeRouter を使用",
    "status.signedOut": "サインアウト中",
    "status.title": "CodeRouter",
    "step.connect": "アカウントを接続",
    "step.connect.body": "CodeRouter は接続したアカウント間でフェイルオーバーします。各アカウントは cmux が CodeRouter に送り、このアプリには見えません。",
    "step.connect.count": "{n} 件接続済み",
    "step.connect.empty": "接続できるものはまだありません。キーを追加するか、プロバイダーの CLI にサインインしてもう一度確認してください。",
    "step.connect.none": "未接続",
    "step.detect": "手元にあるものを確認",
    "step.detect.body": "cmux はこの Mac のサインインとキーを確認します。読むのは名前とメールだけで、キーは読みません。",
    "step.detect.empty": "この Mac にサインインやキーはありません。次のステップでキーを貼り付けられます。",
    "step.detect.found": "この Mac で {n} 件見つかりました",
    "step.detect.none": "まだ何も見つかっていません",
    "step.detect.scanning": "この Mac を確認中…",
    "step.share": "チームと共有",
    "step.share.allShared": "すべて共有済み",
    "step.share.body": "新しいアカウントは非公開です。チームの API キーとマシンは共有アカウントだけを使います。",
    "step.share.nothing": "先にアカウントを接続してください。",
    "step.share.personal": "個人: 不要",
    "step.share.personalBody": "個人スコープです。あなたのアカウントはすでにあなたのマシンとキーで使われます。",
    "step.share.private": "{n} 件が非公開",
    "step.test": "テストを送信",
    "step.test.body": "cmux は CodeRouter 経由でごく短いプロンプトを 1 つ送り、応答したモデルとアカウントを表示します。",
    "step.use": "CodeRouter を使う",
    "step.use.agents": "エージェントは CodeRouter を使用",
    "step.use.body": "cmux で起動するエージェントを CodeRouter 経由にするか、他のツール用に API キーを作成します。",
    "step.use.keys": "API キー {n} 件",
    "step.use.none": "まだ使われていません",
    "tab.keys": "キー",
    "tab.overview": "概要",
    "tab.routing": "ルーティング",
    "tab.setup": "設定",
    "test.detail": "{account} 経由 · {age}",
    "test.failed": "失敗: {message}",
    "test.never": "未実行",
    "test.ok": "{model} · {latency}",
    "test.request": "リクエスト {id}",
    "usage.24h": "24 時間",
    "usage.30d": "30 日",
    "usage.7d": "7 日",
    "usage.byAccount": "アカウント別",
    "usage.byKey": "キー別",
    "usage.byModel": "モデル別",
    "usage.empty": "この期間のリクエストはありません。",
    "usage.none": "今日のリクエストはありません",
    "usage.note": "金額はトークンの API 定価で、請求額ではありません。",
    "usage.short": "{tokens} トークン · {usd}",
    "usage.totals": "{tokens} トークン · {requests} リクエスト",
    "use.agents": "cmux のエージェント",
    "use.agents.off": "それぞれのサインインを使用",
    "use.agents.on": "CodeRouter を使用",
    "visibility.private": "非公開",
    "visibility.team": "共有",
    "wizard.counter": "ステップ {n} / {total}"
  };
  var OP = {
    status: "coderouter.status",
    detect: "coderouter.detect",
    accounts: "coderouter.accounts.list",
    connect: "coderouter.accounts.connect",
    remove: "coderouter.accounts.remove",
    share: "coderouter.accounts.share",
    keys: "coderouter.keys.list",
    createKey: "coderouter.keys.create",
    revokeKey: "coderouter.keys.revoke",
    usage: "coderouter.usage.get",
    route: "coderouter.route.get",
    setOrder: "coderouter.route.order.set",
    test: "coderouter.route.test",
    agents: "coderouter.agents.set",
    reveal: "ui.secret.reveal",
    copySecret: "clipboard.writeSecret",
    openPane: "app.pane.open",
    setSetting: "app.settings.set"
  };
  var ACTION = {
    showAccounts: "accounts.show",
    refreshAccounts: "accounts.refresh",
    reauthenticate: "accounts.reauthenticate",
    connect: "accounts.connect",
    remove: "accounts.remove",
    signIn: "palette.auth.signIn"
  };
  var CHANGED = "coderouter.changed";
  var DETECT_CHANGED = "coderouter.detect.changed";
  var codeOf = (e) => e && typeof e === "object" && ("code" in e) ? String(e.code) : "operation.failed";
  var messageOf = (e) => e instanceof Error ? e.message : String(e);
  var isLocalRefusal = (e) => {
    if (codeOf(e) !== "scope.missing")
      return false;
    const details = e.details;
    return !(details && typeof details === "object" && ("scope" in details));
  };
  function classify(e) {
    const code = codeOf(e);
    const message = messageOf(e);
    if (code === "operation.unsupported" || isLocalRefusal(e))
      return { kind: "unsupported", code, message };
    if (code === "scope.missing" || code === "grant.denied")
      return { kind: "scope", code, message };
    if (code === "auth.required" || code === "coderouter.not_signed_in")
      return { kind: "signedOut", code, message };
    if (code === "user.cancelled")
      return { kind: "cancelled", code, message };
    if (code === "coderouter.unreachable" || code === "network.unreachable" || code === "timeout")
      return { kind: "unreachable", code, message };
    return { kind: "other", code, message };
  }
  var isUnsupported = (e) => codeOf(e) === "operation.unsupported" || isLocalRefusal(e);
  function problemTitle(p) {
    switch (p.kind) {
      case "unsupported":
        return t("problem.unsupported", "Not available in this cmux build");
      case "scope":
        return t("problem.scope", "Permission needed");
      case "signedOut":
        return t("problem.signedOut", "Sign in to cmux");
      case "unreachable":
        return t("problem.unreachable", "Cannot reach CodeRouter");
      case "cancelled":
        return t("problem.cancelled", "Cancelled");
      default:
        return t("problem.other", "Something went wrong");
    }
  }
  function problemMessage(p, op) {
    switch (p.kind) {
      case "unsupported":
        return t("problem.unsupported.body", "This build has no {op} operation yet.", { op });
      case "scope":
        return t("problem.scope.body", "Allow CodeRouter in Settings > Apps to use {op}.", { op });
      case "signedOut":
        return t("problem.signedOut.body", "CodeRouter acts as your cmux account and team.");
      default:
        return p.message;
    }
  }
  var STEPS = ["detect", "connect", "share", "use", "test"];
  var initialProgress = (now = 0) => ({ version: 1, current: "detect", done: [], skipped: [], dismissed: false, finished: false, updated_at_ms: now });
  function parseProgress(raw) {
    if (!raw || typeof raw !== "object")
      return initialProgress();
    const p = raw;
    if (p.version !== 1)
      return initialProgress();
    const steps = (v) => Array.isArray(v) ? v.filter((s) => STEPS.includes(s)) : [];
    return {
      version: 1,
      current: STEPS.includes(p.current) ? p.current : "detect",
      done: steps(p.done),
      skipped: steps(p.skipped),
      dismissed: p.dismissed === true,
      finished: p.finished === true,
      updated_at_ms: typeof p.updated_at_ms === "number" ? p.updated_at_ms : 0
    };
  }
  var notNeeded = (step, f) => step === "share" && f.scopeKind === "personal";
  function provenByData(step, f) {
    switch (step) {
      case "detect":
        return false;
      case "connect":
        return f.connected > 0;
      case "share":
        return f.connected > 0 && f.privateConnected === 0;
      case "use":
        return f.agentsRouted || f.keys > 0;
      case "test":
        return f.lastTestOk;
    }
  }
  function stepState(step, p, f) {
    if (notNeeded(step, f))
      return "notNeeded";
    if (p.done.includes(step) || provenByData(step, f))
      return "done";
    if (p.skipped.includes(step))
      return "skipped";
    return step === p.current ? "current" : "todo";
  }
  var settled = (s) => s === "done" || s === "skipped" || s === "notNeeded";
  function nextOpen(p, f, from = null) {
    const start = from ? STEPS.indexOf(from) + 1 : 0;
    for (let i = start;i < STEPS.length; i++)
      if (!settled(stepState(STEPS[i], p, f)))
        return STEPS[i];
    return null;
  }
  function remaining(p, f) {
    return STEPS.filter((s) => !settled(stepState(s, p, f))).length;
  }
  function fraction(p, f) {
    const applicable = STEPS.filter((s) => !notNeeded(s, f));
    return applicable.filter((s) => settled(stepState(s, p, f))).length / applicable.length;
  }
  var shouldShow = (p, f) => f.signedIn && !p.dismissed && !p.finished;
  var add = (list, s) => list.includes(s) ? list : [...list, s];
  var without = (list, s) => list.filter((x) => x !== s);
  function advance(p, f, from) {
    const next = nextOpen(p, f, from) ?? nextOpen(p, f);
    return next ? { ...p, current: next } : { ...p, finished: true };
  }
  function reduce(p, e, f, now) {
    const stamp = (q) => ({ ...q, updated_at_ms: now });
    switch (e.type) {
      case "next":
        return stamp(advance({ ...p, done: add(p.done, p.current), skipped: without(p.skipped, p.current) }, f, p.current));
      case "complete": {
        const q = { ...p, done: add(p.done, e.step), skipped: without(p.skipped, e.step) };
        return stamp(e.step === p.current ? advance(q, f, e.step) : q);
      }
      case "skip":
        return stamp(advance(p.done.includes(p.current) ? p : { ...p, skipped: add(p.skipped, p.current) }, f, p.current));
      case "back": {
        let i = STEPS.indexOf(p.current) - 1;
        while (i > 0 && notNeeded(STEPS[i], f))
          i--;
        return stamp({ ...p, current: STEPS[Math.max(0, i)] });
      }
      case "goto":
        return stamp({ ...p, current: e.step, finished: false, dismissed: false });
      case "dismiss":
        return stamp({ ...p, dismissed: true });
      case "restart":
        return stamp({ ...p, dismissed: false, finished: false, current: nextOpen({ ...p, skipped: [] }, f) ?? "detect", skipped: [] });
    }
  }
  var STORAGE = { onboarding: "onboarding", lastTest: "lastTest" };
  var VARIANTS = ["checklist", "wizard", "tabs"];
  var DEFAULT_VARIANT = "checklist";
  var [variantOverride, setVariantOverride] = signal(null);
  function variant() {
    const o = variantOverride();
    if (o)
      return o;
    const v = cmux.app.settings().variant;
    return VARIANTS.includes(v) ? v : DEFAULT_VARIANT;
  }
  var nextVariant = (v) => VARIANTS[(VARIANTS.indexOf(v) + 1) % VARIANTS.length];
  async function cycleVariant() {
    const next = nextVariant(variant());
    setVariantOverride(next);
    try {
      await cmux.call(OP.setSetting, { key: "variant", value: next });
    } catch (e) {
      if (!isUnsupported(e))
        cmux.log("variant setting not saved:", String(e));
    }
    return next;
  }
  function applyLocale(ctx = {}) {
    const override = cmux.app.settings().language;
    setLocale(override && override !== "auto" ? String(override) : typeof ctx.locale === "string" ? ctx.locale : "en");
  }
  var [progress, setProgress] = signal(initialProgress());
  var [progressLoaded, setProgressLoaded] = signal(false);
  var loading = null;
  function loadProgress() {
    loading ??= Promise.all([cmux.storage.get(STORAGE.onboarding).catch(() => null), cmux.storage.get(STORAGE.lastTest).catch(() => null)]).then(([p, last]) => {
      setProgress(parseProgress(p));
      if (last && typeof last === "object")
        setLastTest(last);
      setProgressLoaded(true);
    });
    return loading;
  }
  function onboard(event, facts) {
    const next = reduce(progress(), event, facts, Date.now());
    setProgress(next);
    cmux.storage.set(STORAGE.onboarding, next).catch((e) => cmux.log("onboarding progress not saved:", String(e)));
    return next;
  }
  var [lastTest, setLastTest] = signal(null);
  var [createdKey, setCreatedKey] = signal(null);
  var [busySet, setBusySet] = signal(new Set);
  var isBusy = (key) => busySet().has(key);
  async function withBusy(key, fn) {
    setBusySet((s) => new Set([...s, key]));
    try {
      return await fn();
    } finally {
      setBusySet((s) => new Set([...s].filter((k) => k !== key)));
    }
  }
  var [notice, setNoticeSignal] = signal(null);
  var noticeTimer = null;
  function say(tone, text) {
    setNoticeSignal({ tone, text });
    if (noticeTimer !== null)
      cmux.timer.clear(noticeTimer);
    noticeTimer = cmux.timer.after(6000, () => {
      noticeTimer = null;
      setNoticeSignal(null);
    });
  }
  function report(e, op) {
    const p = classify(e);
    if (p.kind === "cancelled")
      return;
    say("danger", `${problemTitle(p)}. ${problemMessage(p, op)}`);
  }
  async function opOrAction(op, params, action, args) {
    try {
      return { via: "op", value: await cmux.call(op, params) };
    } catch (e) {
      if (!isUnsupported(e))
        throw e;
      await cmux.actions.run(action, args);
      return { via: "action" };
    }
  }
  var connect = (provider, name) => withBusy(`connect:${provider}`, async () => {
    try {
      const r = await opOrAction(OP.connect, { provider }, ACTION.connect, { provider });
      if (r.via === "action") {
        say("secondary", t("notice.connectHandedOff", "Finish connecting {name} in cmux.", { name }));
        return true;
      }
      if (r.value.status !== "connected")
        return false;
      say("success", t("notice.connected", "{name} connected. It stays private until you share it.", { name }));
      return true;
    } catch (e) {
      report(e, OP.connect);
      return false;
    }
  });
  async function reauthenticate(provider) {
    try {
      await cmux.actions.run(ACTION.reauthenticate, { provider });
    } catch (e) {
      report(e, ACTION.reauthenticate);
    }
  }
  var remove = (account) => withBusy(`account:${account.id}`, async () => {
    try {
      const r = await opOrAction(OP.remove, { account: account.id }, ACTION.remove, { account: account.id });
      if (r.via === "op" && r.value.removed)
        say("secondary", t("notice.removed", "{label} removed from CodeRouter.", { label: account.label }));
    } catch (e) {
      report(e, OP.remove);
    }
  });
  var share = (accounts, visibility) => withBusy(`share:${accounts.join(",")}`, async () => {
    if (!accounts.length)
      return false;
    try {
      await cmux.call(OP.share, { accounts, visibility });
      say("success", visibility === "team" ? t("notice.shared", "Shared with your team.") : t("notice.private", "Now private to you."));
      return true;
    } catch (e) {
      report(e, OP.share);
      return false;
    }
  });
  var createKey = (label) => withBusy("key:create", async () => {
    const name = label.trim() || t("key.defaultLabel", "cmux key");
    try {
      const created = await cmux.call(OP.createKey, { label: name, present: "sheet" });
      setCreatedKey(created);
      return created;
    } catch (e) {
      report(e, OP.createKey);
      return null;
    }
  });
  async function revealKey(handle) {
    try {
      await cmux.call(OP.reveal, { handle });
    } catch (e) {
      report(e, OP.reveal);
    }
  }
  async function copyKey(handle) {
    try {
      await cmux.call(OP.copySecret, { handle });
      say("success", t("notice.copied", "Copied. The clipboard clears in 60 seconds."));
    } catch (e) {
      report(e, OP.copySecret);
    }
  }
  var revokeKey = (id) => withBusy(`key:${id}`, async () => {
    try {
      await cmux.call(OP.revokeKey, { key: id });
      setCreatedKey((k) => k && k.key.id === id ? null : k);
    } catch (e) {
      report(e, OP.revokeKey);
    }
  });
  var setAgentsRouted = (enabled) => withBusy("agents", async () => {
    try {
      await cmux.call(OP.agents, { enabled });
      say("success", enabled ? t("notice.agentsOn", "New agent sessions in cmux use CodeRouter.") : t("notice.agentsOff", "Agents use their own sign-ins again."));
      return true;
    } catch (e) {
      report(e, OP.agents);
      return false;
    }
  });
  var setOrder = (surface, accounts) => withBusy(`route:${surface}`, async () => {
    try {
      await cmux.call(OP.setOrder, { surface, accounts });
    } catch (e) {
      report(e, OP.setOrder);
    }
  });
  var runTest = () => withBusy("test", async () => {
    let result;
    try {
      result = { ...await cmux.call(OP.test, { surface: "auto" }), at_ms: Date.now() };
    } catch (e) {
      const p = classify(e);
      result = { ok: false, at_ms: Date.now(), error: { code: p.code, message: problemMessage(p, OP.test) } };
    }
    setLastTest(result);
    cmux.storage.set(STORAGE.lastTest, result).catch(() => {
      return;
    });
    return result;
  });
  async function openPane(kind) {
    try {
      await cmux.call(OP.openPane, { kind });
      return "pane";
    } catch (e) {
      if (!isUnsupported(e))
        report(e, OP.openPane);
      if (kind === "dashboard")
        await cmux.actions.run(ACTION.showAccounts, {}).catch((e2) => report(e2, ACTION.showAccounts));
      else
        say("secondary", t("notice.noPanes", "This cmux build cannot open app panes yet. Use Next CodeRouter Variant for the sidebar checklist."));
      return "fallback";
    }
  }
  async function signIn() {
    try {
      await cmux.actions.run(ACTION.signIn, {});
    } catch (e) {
      report(e, ACTION.signIn);
    }
  }
  function query(op, params = () => ({}), events = [CHANGED]) {
    const [value, setValue] = signal(undefined);
    const [problem, setProblem] = signal(null);
    const [loading, setLoading] = signal(true);
    let latest = 0;
    let current = {};
    const load = () => {
      const mine = ++latest;
      setLoading(true);
      cmux.call(op, current).then((v) => {
        if (mine !== latest)
          return;
        setValue(() => v);
        setProblem(null);
      }).catch((e) => {
        if (mine === latest)
          setProblem(classify(e));
      }).finally(() => {
        if (mine === latest)
          setLoading(false);
      });
    };
    for (const stream of events)
      cmux.events.on(stream, load);
    effect(() => {
      current = params();
      load();
    });
    return Object.assign(() => value(), { problem, loading, refresh: load });
  }
  var idle = () => Object.assign(() => {
    return;
  }, { problem: () => null, loading: () => false, refresh: () => {
    return;
  } });
  function core(light = false) {
    const status = query(OP.status);
    const detected = light ? idle() : query(OP.detect, () => ({}), [DETECT_CHANGED, CHANGED]);
    const accounts = light ? idle() : query(OP.accounts);
    const keys = light ? idle() : query(OP.keys);
    const facts = computed(() => factsOf(status(), accounts(), keys(), lastTest()?.ok === true));
    return { status, detected, accounts, keys, facts };
  }
  function factsOf(status, accounts, keys, lastTestOk) {
    const list = accounts ?? [];
    return {
      signedIn: status?.signed_in === true,
      scopeKind: status?.scope?.kind ?? null,
      connected: list.length,
      privateConnected: list.filter((a) => a.visibility === "private" && a.mine).length,
      agentsRouted: status?.agents_routed === true,
      keys: (keys ?? []).filter((k) => !k.revoked).length,
      lastTestOk
    };
  }
  function insights() {
    const configured = cmux.app.settings().usageWindow;
    const [usageWindow, setUsageWindow] = signal(configured === "24h" || configured === "30d" ? configured : "7d");
    const [usageGroup, setUsageGroup] = signal("account");
    const [surface, setSurface] = signal("responses");
    const usage = query(OP.usage, () => ({ window: usageWindow(), group_by: usageGroup() }));
    const route = query(OP.route, () => ({ surface: surface() }));
    return { usageWindow, setUsageWindow, usageGroup, setUsageGroup, usage, surface, setSurface, route };
  }
  function formatTokens(n) {
    if (!Number.isFinite(n) || n <= 0)
      return "0";
    if (n < 1000)
      return String(Math.round(n));
    if (n < 1e6)
      return `${trim(n / 1000)}k`;
    if (n < 1e9)
      return `${trim(n / 1e6)}M`;
    return `${trim(n / 1e9)}B`;
  }
  var trim = (v) => v >= 100 ? String(Math.round(v)) : v.toFixed(1).replace(/\.0$/, "");
  function formatUsd(n) {
    if (!Number.isFinite(n) || n <= 0)
      return "$0";
    if (n < 0.01)
      return "<$0.01";
    if (n < 100)
      return `$${n.toFixed(2)}`;
    return `$${Math.round(n).toLocaleString("en-US")}`;
  }
  function formatLatency(ms) {
    if (!Number.isFinite(ms) || ms < 0)
      return "–";
    return ms < 1000 ? `${Math.round(ms)} ms` : `${(ms / 1000).toFixed(1)} s`;
  }
  function relativeAge(ms, now) {
    if (!ms)
      return t("age.never", "never used");
    const s = Math.max(0, (now - ms) / 1000);
    if (s < 60)
      return t("age.now", "just now");
    if (s < 3600)
      return t("age.minutes", "{n} min ago", { n: Math.floor(s / 60) });
    if (s < 86400)
      return t("age.hours", "{n} h ago", { n: Math.floor(s / 3600) });
    return t("age.days", "{n} d ago", { n: Math.floor(s / 86400) });
  }
  function healthTone(h) {
    switch (h) {
      case "ok":
        return "success";
      case "degraded":
        return "warning";
      case "down":
        return "danger";
      default:
        return "tertiary";
    }
  }
  function healthWord(h) {
    switch (h) {
      case "ok":
        return t("health.ok", "Healthy");
      case "degraded":
        return t("health.degraded", "Degraded");
      case "down":
        return t("health.down", "Down");
      default:
        return t("health.unknown", "Unknown");
    }
  }
  var isHealthyAccount = (a) => a.state === "active" || a.state === "refreshing";
  function accountTone(a, now) {
    if (!isHealthyAccount(a))
      return a.state === "disabled" ? "tertiary" : "danger";
    if (a.cooldown_until_ms && a.cooldown_until_ms > now)
      return "warning";
    return "success";
  }
  var accountStateWord = (a, now) => stateWord(a.state, a.cooldown_until_ms, now);
  function stateWord(state, cooldownUntil, now) {
    if (cooldownUntil && cooldownUntil > now && (state === "active" || state === "refreshing"))
      return t("account.cooling", "Cooling down");
    switch (state) {
      case "active":
        return t("account.active", "Active");
      case "refreshing":
        return t("account.refreshing", "Refreshing");
      case "expired":
        return t("account.expired", "Expired");
      case "broken":
        return t("account.broken", "Needs sign-in");
      case "disabled":
        return t("account.disabled", "Disabled");
      default:
        return state;
    }
  }
  var visibilityWord = (v) => v === "team" ? t("visibility.team", "Shared") : t("visibility.private", "Private");
  function localStatusWord(d) {
    switch (d.status) {
      case "signed_in":
        return d.provider === "openai" || d.provider === "anthropic" || d.provider === "openrouter" ? t("detect.key", "Key found") : t("detect.signedIn", "Signed in");
      case "expired":
        return t("detect.expired", "Expired");
      case "unknown":
        return t("detect.unknown", "Found");
      default:
        return t("detect.missing", "Not found");
    }
  }
  var PROVIDER_PRIORITY = ["codex", "claude", "openai", "anthropic", "openrouter", "bedrock"];
  var rank = (p) => {
    const i = PROVIDER_PRIORITY.indexOf(p);
    return i < 0 ? PROVIDER_PRIORITY.length : i;
  };
  var isConnected = (provider, accounts) => accounts.some((a) => a.provider === provider);
  function recommend(detected, accounts) {
    return detected.filter((d) => d.linkable && d.status === "signed_in" && !isConnected(d.provider, accounts)).sort((a, b) => rank(a.provider) - rank(b.provider));
  }
  var needsReauth = (detected) => detected.filter((d) => d.status === "expired");
  function shares(rows) {
    const max = rows.reduce((m, r) => Math.max(m, r.total_tokens), 0);
    return rows.map((r) => max > 0 ? r.total_tokens / max : 0);
  }
  function moveTo(ids, id, index) {
    const rest = ids.filter((x) => x !== id);
    if (rest.length === ids.length)
      return [...ids];
    const at = Math.max(0, Math.min(index, rest.length));
    return [...rest.slice(0, at), id, ...rest.slice(at)];
  }
  function usageSummary(u) {
    if (!u || u.requests === 0)
      return t("usage.none", "No requests today");
    return t("usage.short", "{tokens} tok · {usd}", { tokens: formatTokens(u.total_tokens), usd: formatUsd(u.api_equivalent_usd) });
  }
  var dot = (tone, size = 8) => Circle({ fill: tone }).frame({ width: size, height: size });
  var caption = (text) => Text(text).font("caption").secondary().lineLimit(2);
  function header(title, trailing = null) {
    return HStack({ spacing: 6 }, [Text(title).font("caption").weight("semibold").color("secondary"), Spacer(), trailing]).padding({ top: 10, leading: 0, bottom: 2, trailing: 0 });
  }
  var small = (title, action) => Button(title, action).font("caption");
  function choice(options, current, set) {
    return HStack({ spacing: 10 }, options.map(([value, title]) => Text(title).font("caption").weight(() => current() === value ? "semibold" : "regular").color(() => current() === value ? "primary" : "secondary").cursor("pointer").onTap(() => set(value))));
  }
  function bar(fraction, width = 120) {
    return HStack({ spacing: 0 }, [Capsule({ fill: "accent" }).frame(() => ({ width: Math.max(2, Math.round(fraction() * width)), height: 4 })), Spacer()]).frame({ width, height: 4 });
  }
  function problemView(problem, op, retry) {
    return VStack({ spacing: 6 }, [
      EmptyState({ title: problemTitle(problem), message: problemMessage(problem, op), symbol: problem.kind === "signedOut" ? "person.crop.circle.badge.questionmark" : problem.kind === "unsupported" ? "puzzlepiece.extension" : "exclamationmark.triangle" }),
      problem.kind === "signedOut" || problem.kind === "unsupported" || problem.kind === "scope" ? problem.kind === "signedOut" ? HStack([Spacer(), Button(t("action.signIn", "Sign In"), signIn), Spacer()]) : null : HStack([Spacer(), Button(t("action.retry", "Try Again"), retry), Spacer()])
    ]);
  }
  function loaded(q, op, body, loadingText = t("state.loading", "Loading…")) {
    return () => {
      const v = q();
      const p = q.problem();
      if (p && v === undefined)
        return problemView(p, op, q.refresh);
      if (v === undefined)
        return caption(loadingText);
      return body(v);
    };
  }
  var noticeLine = () => () => {
    const n = notice();
    return n ? Text(n.text).font("caption").color(n.tone).lineLimit(3).padding({ top: 6, leading: 0, bottom: 0, trailing: 0 }) : null;
  };
  var PASTE_PROVIDERS = [
    ["openai", "OpenAI API"],
    ["anthropic", "Anthropic API"],
    ["openrouter", "OpenRouter"],
    ["claude", "Claude Code"]
  ];
  function stepSpec(step, d) {
    switch (step) {
      case "detect":
        return {
          title: t("step.detect", "See what you have"),
          sentence: t("step.detect.body", "cmux checks this Mac for sign-ins and keys. It reads only names and emails, never a key."),
          summary: () => {
            const found = (d.detected() ?? []).filter((x) => x.status !== "missing").length;
            return found ? t("step.detect.found", "{n} found on this Mac", { n: found }) : t("step.detect.none", "Nothing found yet");
          },
          body: () => detectBody(d)
        };
      case "connect":
        return {
          title: t("step.connect", "Connect accounts"),
          sentence: t("step.connect.body", "CodeRouter fails over between the accounts you connect. cmux sends each one to CodeRouter; this app never sees it."),
          summary: () => {
            const n = (d.accounts() ?? []).length;
            return n ? t("step.connect.count", "{n} connected", { n }) : t("step.connect.none", "None connected");
          },
          body: () => VStack([connectBody(d)])
        };
      case "share":
        return {
          title: t("step.share", "Share with your team"),
          sentence: t("step.share.body", "New accounts are private. Your team's API keys and machines use only shared accounts."),
          summary: () => {
            if (d.status()?.scope?.kind === "personal")
              return t("step.share.personal", "Personal: not needed");
            if (!mine(d).length)
              return t("step.share.nothing", "Connect an account first.");
            const n = mine(d).filter((a) => a.visibility === "private").length;
            return n ? t("step.share.private", "{n} private", { n }) : t("step.share.allShared", "All shared");
          },
          body: () => VStack([shareBody(d)])
        };
      case "use":
        return {
          title: t("step.use", "Use CodeRouter"),
          sentence: t("step.use.body", "Route the agents you start in cmux through CodeRouter, or create an API key for other tools."),
          summary: () => d.status()?.agents_routed ? t("step.use.agents", "Agents use CodeRouter") : keyCount(d) ? t("step.use.keys", "{n} API keys", { n: keyCount(d) }) : t("step.use.none", "Not used yet"),
          body: () => useBody(d)
        };
      case "test":
        return {
          title: t("step.test", "Send a test"),
          sentence: t("step.test.body", "cmux sends one tiny prompt through CodeRouter and shows which model and account answered."),
          summary: () => testSummary(lastTest()),
          body: () => testBody()
        };
    }
  }
  var mine = (d) => (d.accounts() ?? []).filter((a) => a.mine);
  var keyCount = (d) => (d.keys() ?? []).filter((k) => !k.revoked).length;
  function line(title, detail, trailing) {
    return HStack({ spacing: 8 }, [
      VStack({ spacing: 0 }, [Text(title).lineLimit(1), () => detail() ? Text(detail).font("caption").secondary().lineLimit(1).truncation("middle") : null]).layoutPriority(1),
      Spacer(),
      trailing
    ]).frame({ minHeight: 28 });
  }
  function busyOr(key, view) {
    return () => isBusy(key) ? ProgressView().frame({ width: 16, height: 16 }) : view();
  }
  function detectBody(d) {
    return VStack({ spacing: 4 }, [
      loaded(d.detected, OP.detect, (all) => {
        const found = all.filter((x) => x.status !== "missing");
        if (!found.length)
          return caption(t("step.detect.empty", "No sign-ins or keys on this Mac. You can paste a key in the next step."));
        return VStack({ spacing: 2 }, found.map((x) => line(() => x.name, () => [x.identity, x.plan].filter(Boolean).join(" · ") || x.source || null, () => Text(localStatusWord(x)).font("caption").color(x.status === "signed_in" ? "success" : x.status === "expired" ? "warning" : "secondary"))));
      }, t("step.detect.scanning", "Checking this Mac…")),
      HStack([Spacer(), small(t("action.rescan", "Check Again"), () => d.detected.refresh())])
    ]);
  }
  function addKeyMenu(accounts, exclude = []) {
    return Menu(t("action.addKey", "Add with a Key…"), PASTE_PROVIDERS.filter(([p]) => !exclude.includes(p) && !isConnected(p, accounts())).map(([p, name]) => Button(name, () => connect(p, name)))).font("caption");
  }
  function connectRow(x) {
    return line(() => x.name, () => x.identity ?? null, busyOr(`connect:${x.provider}`, () => small(t("action.connect", "Connect"), () => connect(x.provider, x.name))));
  }
  function connectBody(d) {
    return loaded(d.accounts, OP.accounts, (accounts) => {
      const detected = d.detected() ?? [];
      const best = recommend(detected, accounts);
      const expired = needsReauth(detected).filter((x) => !isConnected(x.provider, accounts));
      const others = PASTE_PROVIDERS.filter(([p]) => !isConnected(p, accounts) && !best.some((b) => b.provider === p));
      return VStack({ spacing: 2 }, [
        ...accounts.map((a) => line(() => a.name, () => a.label, () => Text(t("state.connected", "Connected")).font("caption").color("success"))),
        ...best.map(connectRow),
        ...expired.map((x) => line(() => x.name, () => t("detect.expired", "Expired"), () => small(t("action.signInAgain", "Sign In Again"), () => reauthenticate(x.provider)))),
        others.length ? HStack([Spacer(), addKeyMenu(() => accounts, best.map((b) => b.provider))]) : null,
        !accounts.length && !best.length ? caption(t("step.connect.empty", "Nothing to connect yet. Add a key, or sign in to a provider's CLI and check again.")) : null
      ]);
    });
  }
  function shareBody(d) {
    return loaded(d.accounts, OP.accounts, () => {
      const scope = d.status()?.scope;
      if (scope?.kind === "personal")
        return caption(t("step.share.personalBody", "You are in your personal scope: your accounts already serve your own machines and keys."));
      const own = mine(d);
      const privateIds = own.filter((a) => a.visibility === "private").map((a) => a.id);
      if (!own.length)
        return caption(t("step.share.nothing", "Connect an account first."));
      return VStack({ spacing: 2 }, [
        ...own.map((a) => line(() => a.name, () => a.label, busyOr(`share:${a.id}`, () => a.visibility === "team" ? small(t("action.makePrivate", "Make Private"), () => share([a.id], "private")) : small(t("action.share", "Share"), () => share([a.id], "team"))))),
        privateIds.length > 1 ? HStack([Spacer(), busyOr(`share:${privateIds.join(",")}`, () => small(t("action.shareAll", "Share All with {team}", { team: scope?.team_name ?? "" }), () => share(privateIds, "team")))]) : null
      ]);
    });
  }
  function useBody(d) {
    const [label, setLabel] = signal("");
    return VStack({ spacing: 6 }, [
      line(() => t("use.agents", "cmux agents"), () => d.status()?.agents_routed ? t("use.agents.on", "Use CodeRouter") : t("use.agents.off", "Use their own sign-ins"), busyOr("agents", () => d.status()?.agents_routed ? small(t("action.turnOff", "Turn Off"), () => setAgentsRouted(false)) : small(t("action.turnOn", "Turn On"), () => setAgentsRouted(true)))),
      HStack({ spacing: 8 }, [
        TextField(label, { placeholder: t("key.placeholder", "Key name, e.g. editor"), onEdit: setLabel, onSubmit: (text) => createKey(text) }),
        busyOr("key:create", () => small(t("action.createKey", "Create Key"), () => createKey(label())))
      ]),
      createdKeyLine()
    ]);
  }
  function createdKeyLine() {
    return () => {
      const k = createdKey();
      if (!k)
        return null;
      const live = !k.handle_expires_at_ms || k.handle_expires_at_ms > Date.now();
      return HStack({ spacing: 8 }, [
        Icon("key").color("success"),
        Text(t("key.created", "{label} created ({prefix}…)", { label: k.key.label, prefix: k.key.prefix })).font("caption").lineLimit(1),
        Spacer(),
        live ? small(t("action.show", "Show"), () => revealKey(k.handle)) : null,
        live ? small(t("action.copy", "Copy"), () => copyKey(k.handle)) : null
      ]);
    };
  }
  function testSummary(r) {
    if (!r)
      return t("test.never", "Not run yet");
    if (!r.ok)
      return t("test.failed", "Failed: {message}", { message: r.error?.message ?? "" });
    return t("test.ok", "{model} in {latency}", { model: r.model ?? "?", latency: formatLatency(r.latency_ms ?? NaN) });
  }
  function testBody() {
    return VStack({ spacing: 6 }, [
      HStack([busyOr("test", () => Button(t("action.runTest", "Run Test"), () => runTest())), Spacer()]),
      () => {
        const r = lastTest();
        if (!r)
          return null;
        if (!r.ok)
          return Text(testSummary(r)).font("caption").color("danger").lineLimit(3);
        return VStack({ spacing: 2 }, [
          HStack({ spacing: 6 }, [Icon("checkmark.circle.fill").color("success"), Text(testSummary(r)).font("callout").monospaced()]),
          caption(t("test.detail", "via {account} · {age}", { account: [r.provider_name, r.account_label].filter(Boolean).join(" "), age: relativeAge(r.at_ms, Date.now()) })),
          r.request_id ? Text(t("test.request", "Request {id}", { id: r.request_id })).font("caption2").color("tertiary").monospaced().lineLimit(1).truncation("middle") : null
        ]);
      }
    ]);
  }
  var symbolFor = (s) => s === "done" ? "checkmark.circle.fill" : s === "skipped" ? "arrow.uturn.right.circle" : s === "notNeeded" ? "minus.circle" : s === "current" ? "circle.inset.filled" : "circle";
  var toneFor = (s) => s === "done" ? "success" : s === "current" ? "accent" : "tertiary";
  function gate(d, layout) {
    const mode = computed(() => {
      if (!progressLoaded())
        return "loading";
      if (d.status()?.signed_in === false)
        return "signedOut";
      const p = progress();
      return p.finished || nextOpen(p, d.facts()) === null ? "done" : "steps";
    });
    return () => {
      switch (mode()) {
        case "loading":
          return caption(t("state.loading", "Loading…"));
        case "signedOut":
          return VStack({ spacing: 6 }, [
            EmptyState({ title: t("onboarding.signIn", "Sign in to cmux to set up CodeRouter"), message: t("onboarding.signIn.body", "CodeRouter acts as your cmux account and team."), symbol: "person.crop.circle" }),
            Button(t("action.signIn", "Sign In"), signIn)
          ]);
        case "done":
          return VStack({ spacing: 6 }, [
            EmptyState({ title: t("onboarding.done", "CodeRouter is ready"), message: t("onboarding.done.body", "Your agents and keys fail over between your connected accounts."), symbol: "checkmark.seal" }),
            () => lastTest()?.ok ? HStack([Spacer(), Icon("checkmark.circle.fill").color("success"), Text(testSummary(lastTest())).font("callout").monospaced().lineLimit(1).fixedSize("horizontal"), Spacer()]) : null,
            HStack({ spacing: 16 }, [Spacer(), small(t("action.openDashboard", "Open Dashboard"), () => openPane("dashboard")), small(t("action.reviewSetup", "Review Setup"), () => onboard({ type: "restart" }, d.facts())), Spacer()])
          ]);
        default:
          return layout();
      }
    };
  }
  function wizard(d) {
    const current = computed(() => progress().current);
    return VStack({ spacing: 0 }, [
      gate(d, () => {
        const step = current();
        const spec = stepSpec(step, d);
        const index = STEPS.indexOf(step);
        return VStack({ spacing: 12 }, [
          HStack({ spacing: 6 }, [
            ...STEPS.map((s) => Circle({ fill: () => toneFor(stepState(s, progress(), d.facts())) }).frame({ width: 7, height: 7 })),
            Spacer(),
            Text(t("wizard.counter", "Step {n} of {total}", { n: index + 1, total: STEPS.length })).font("caption").color("tertiary")
          ]),
          VStack({ spacing: 4 }, [Text(spec.title).font("title2").weight("semibold"), caption(spec.sentence)]),
          spec.body(),
          noticeLine(),
          Spacer(),
          Divider(),
          HStack({ spacing: 10 }, [
            index > 0 ? small(t("action.back", "Back"), () => onboard({ type: "back" }, d.facts())) : null,
            small(t("action.skipSetup", "Skip Setup"), () => onboard({ type: "dismiss" }, d.facts())),
            Spacer(),
            small(t("action.skip", "Skip"), () => onboard({ type: "skip" }, d.facts())),
            Button(step === "test" ? t("action.finish", "Finish") : t("action.continue", "Continue"), () => onboard({ type: "next" }, d.facts()))
          ])
        ]).padding(16);
      })
    ]);
  }
  function checklist(d) {
    const [open, setOpen] = signal(null);
    const expanded = () => open() ?? progress().current;
    return VStack({ spacing: 0 }, [
      gate(d, () => VStack({ spacing: 2 }, [
        HStack({ spacing: 6 }, [
          Text(t("checklist.title", "Set up CodeRouter")).font("caption").weight("semibold").color("secondary"),
          Spacer(),
          Text(() => t("checklist.left", "{n} left", { n: remaining(progress(), d.facts()) })).font("caption").color("tertiary"),
          small(t("action.hide", "Hide"), () => onboard({ type: "dismiss" }, d.facts()))
        ]),
        ProgressView(() => fraction(progress(), d.facts())).frame({ height: 4 }),
        ...STEPS.map((step) => checklistItem(d, step, expanded, setOpen))
      ])),
      noticeLine()
    ]);
  }
  function checklistItem(d, step, expanded, setOpen) {
    const spec = stepSpec(step, d);
    const state = computed(() => stepState(step, progress(), d.facts()));
    const isOpen = computed(() => expanded() === step);
    return VStack({ spacing: 2 }, [
      Row({ title: spec.title, subtitle: spec.summary, symbol: () => symbolFor(state()), tint: () => toneFor(state()), selected: isOpen }).onTap(() => setOpen(isOpen() ? null : step)),
      () => isOpen() && state() !== "notNeeded" ? VStack({ spacing: 6 }, [
        caption(spec.sentence),
        spec.body(),
        HStack({ spacing: 10 }, [
          Spacer(),
          state() === "done" ? null : small(t("action.skip", "Skip"), () => (setOpen(null), onboard({ type: "skip" }, d.facts()))),
          small(t("action.done", "Done"), () => (setOpen(null), onboard({ type: "complete", step }, d.facts())))
        ])
      ]).padding({ top: 4, leading: 26, bottom: 8, trailing: 4 }) : null
    ]);
  }
  function page(d, inset = 16) {
    return VStack({ spacing: 0 }, [
      gate(d, () => VStack({ spacing: 14 }, [
        HStack({ spacing: 8 }, [
          ProgressView(() => fraction(progress(), d.facts())),
          Text(() => t("checklist.left", "{n} left", { n: remaining(progress(), d.facts()) })).font("caption").color("tertiary"),
          small(t("action.skipSetup", "Skip Setup"), () => onboard({ type: "dismiss" }, d.facts()))
        ]),
        ...STEPS.map((step, i) => {
          const spec = stepSpec(step, d);
          const state = computed(() => stepState(step, progress(), d.facts()));
          return VStack({ spacing: 6 }, [
            HStack({ spacing: 8 }, [
              Icon(() => symbolFor(state())).color(() => toneFor(state())),
              Text(`${i + 1}. ${spec.title}`).font("headline"),
              Spacer(),
              Text(spec.summary).font("caption").color("secondary").lineLimit(1)
            ]),
            () => state() === "notNeeded" ? null : VStack({ spacing: 6 }, [caption(spec.sentence), spec.body()]).padding({ top: 0, leading: 26, bottom: 0, trailing: 0 }),
            Divider()
          ]);
        }),
        noticeLine()
      ]).padding(inset))
    ]);
  }
  var setupPending = (d) => shouldShow(progress(), d.facts()) && nextOpen(progress(), d.facts()) !== null;
  function statusSection(d) {
    return loaded(d.status, OP.status, (s) => {
      if (!s.signed_in)
        return VStack({ spacing: 6 }, [
          EmptyState({ title: t("problem.signedOut", "Sign in to cmux"), message: t("problem.signedOut.body", "CodeRouter acts as your cmux account and team."), symbol: "person.crop.circle" }),
          Button(t("action.signIn", "Sign In"), signIn)
        ]);
      const scope = s.scope?.kind === "team" ? s.scope.team_name : t("scope.personal", "Personal");
      return VStack({ spacing: 4 }, [
        HStack({ spacing: 8 }, [
          dot(() => healthTone(s.health), 10),
          Text(t("status.title", "CodeRouter")).font("title3").weight("semibold"),
          Badge(scope, s.scope?.kind === "team" ? "accent" : "secondary"),
          Spacer(),
          Text(healthWord(s.health)).font("caption").color(healthTone(s.health))
        ]),
        caption([s.user?.name, s.agents_routed ? t("status.agentsOn", "agents use CodeRouter") : t("status.agentsOff", "agents use their own sign-ins"), usageSummary(s.usage_today)].filter(Boolean).join(" · ")),
        () => setupPending(d) ? HStack([Spacer(), small(t("action.finishSetup", "Finish Setup"), () => openPane("onboarding"))]) : null
      ]);
    });
  }
  function accountRow(a) {
    const now = Date.now();
    const menu = [
      a.visibility === "private" ? Button(t("action.shareWithTeam", "Share with Team"), () => share([a.id], "team")).disabled(!a.mine) : Button(t("action.makePrivate", "Make Private"), () => share([a.id], "private")).disabled(!a.mine),
      Button(t("action.signInAgain", "Sign In Again"), () => reauthenticate(a.provider)),
      Divider(),
      Button(t("action.remove", "Remove from CodeRouter…"), () => remove(a)).destructive()
    ];
    return Row({
      title: a.label,
      subtitle: `${a.name} · ${accountStateWord(a, now)}`,
      symbol: a.visibility === "team" ? "person.2" : "lock",
      tint: accountTone(a, now),
      badge: visibilityWord(a.visibility)
    }).help(a.mine ? t("account.mine", "You connected this account") : t("account.teammate", "A teammate shared this account")).contextMenu(menu);
  }
  function accountsSection(d) {
    return VStack({ spacing: 2 }, [
      header(t("section.accounts", "Accounts"), () => addKeyMenu(() => d.accounts() ?? [])),
      loaded(d.accounts, OP.accounts, (accounts) => {
        const found = recommend(d.detected() ?? [], accounts);
        if (!accounts.length && !found.length)
          return EmptyState({ title: t("accounts.empty", "No accounts yet"), message: t("accounts.empty.body", "Sign in to a provider's CLI on this Mac, or add a key."), symbol: "person.crop.circle.badge.plus" });
        return VStack({ spacing: 2 }, [
          ...accounts.map(accountRow),
          found.length ? caption(t("accounts.found", "Found on this Mac")) : null,
          ...found.map((x) => line(() => x.name, () => x.identity ?? null, () => isBusy(`connect:${x.provider}`) ? ProgressView().frame({ width: 16, height: 16 }) : small(t("action.connect", "Connect"), () => connect(x.provider, x.name))))
        ]);
      })
    ]);
  }
  function routingSection(i) {
    return VStack({ spacing: 2 }, [
      header(t("section.routing", "Failover order"), choice([
        ["responses", t("route.responses", "OpenAI API")],
        ["messages", t("route.messages", "Anthropic API")]
      ], i.surface, i.setSurface)),
      loaded(i.route, OP.route, (r) => {
        if (!r.order.length)
          return caption(t("route.empty", "No account serves this API yet."));
        const ids = r.order.map((e) => e.account);
        return VStack({ spacing: 2 }, [
          caption(r.strategy === "ordered" ? t("route.ordered", "CodeRouter tries these in order. Drag to change it.") : t("route.headroom", "CodeRouter picks the account with the most room left, in this order on a tie.")),
          Reorderable({ items: () => r.order, key: (e) => e.account, onMove: (id, index) => setOrder(r.surface, moveTo(ids, id, index)) }, (e) => Row({ title: () => e().label, subtitle: () => `${e().name} · ${stateWord(e().state, e().cooldown_until_ms, Date.now())}`, symbol: () => `${ids.indexOf(e().account) + 1}.circle`, tint: () => e().cooldown_until_ms && e().cooldown_until_ms > Date.now() ? "warning" : "secondary" }))
        ]);
      })
    ]);
  }
  function usageSection(i) {
    return VStack({ spacing: 4 }, [
      header(t("section.usage", "Usage"), choice([
        ["24h", t("usage.24h", "24 h")],
        ["7d", t("usage.7d", "7 d")],
        ["30d", t("usage.30d", "30 d")]
      ], i.usageWindow, i.setUsageWindow)),
      choice([
        ["account", t("usage.byAccount", "By account")],
        ["model", t("usage.byModel", "By model")],
        ["key", t("usage.byKey", "By key")]
      ], i.usageGroup, i.setUsageGroup),
      loaded(i.usage, OP.usage, (u) => {
        const f = shares(u.rows);
        return VStack({ spacing: 4 }, [
          HStack({ spacing: 12 }, [
            Text(formatUsd(u.totals.api_equivalent_usd)).font("title3").weight("semibold").monospaced(),
            caption(t("usage.totals", "{tokens} tokens · {requests} requests", { tokens: formatTokens(u.totals.total_tokens), requests: u.totals.requests.toLocaleString("en-US") }))
          ]),
          !u.rows.length ? caption(t("usage.empty", "No requests in this window.")) : VStack({ spacing: 4 }, u.rows.map((row, k) => HStack({ spacing: 8 }, [
            Text(row.label).font("caption").lineLimit(1).truncation("middle").frame({ width: 140 }),
            bar(() => f[k] ?? 0, 110),
            Spacer(),
            Text(formatTokens(row.total_tokens)).font("caption").monospaced().secondary(),
            Text(formatUsd(row.api_equivalent_usd)).font("caption").monospaced().frame({ minWidth: 52 })
          ]))),
          caption(t("usage.note", "Spend is the API list price of the tokens, not your bill."))
        ]);
      })
    ]);
  }
  function keyRow(k) {
    return Row({
      title: k.label,
      subtitle: `${k.prefix}… · ${relativeAge(k.last_used_at_ms, Date.now())}${k.usage_7d ? ` · ${formatTokens(k.usage_7d.total_tokens)} ${t("key.tokens7d", "tok 7 d")}` : ""}`,
      symbol: "key",
      tint: k.revoked ? "tertiary" : "secondary",
      badge: k.revoked ? t("key.revoked", "Revoked") : null
    }).contextMenu(k.revoked ? [] : [Button(t("action.revoke", "Revoke Key…"), () => revokeKey(k.id)).destructive()]);
  }
  function keysSection(d) {
    const [label, setLabel] = signal("");
    return VStack({ spacing: 2 }, [
      header(t("section.keys", "API keys")),
      loaded(d.keys, OP.keys, (keys) => {
        const active = keys.filter((k) => !k.revoked);
        return VStack({ spacing: 2 }, [
          ...active.map(keyRow),
          !active.length ? caption(t("keys.empty", "No keys. A key lets any tool use your team's shared accounts.")) : null
        ]);
      }),
      HStack({ spacing: 8 }, [
        TextField(label, { placeholder: t("key.placeholder", "Key name, e.g. editor"), onEdit: setLabel, onSubmit: (text) => createKey(text) }),
        () => isBusy("key:create") ? ProgressView().frame({ width: 16, height: 16 }) : small(t("action.createKey", "Create Key"), () => createKey(label()))
      ]).padding({ top: 4, leading: 0, bottom: 0, trailing: 0 }),
      createdKeyLine()
    ]);
  }
  function testSection() {
    return VStack({ spacing: 2 }, [header(t("section.test", "Test request")), testBody()]);
  }
  function whenReachable(d, body) {
    const mode = computed(() => {
      const s = d.status();
      if (s === undefined)
        return d.status.problem() ? "problem" : "loading";
      return s.signed_in ? "ok" : "signedOut";
    });
    return () => {
      switch (mode()) {
        case "ok":
          return body();
        case "loading":
          return caption(t("state.loading", "Loading…"));
        default:
          return statusSection(d)();
      }
    };
  }
  function sectionsLayout(d, i) {
    return VStack({ spacing: 8 }, [whenReachable(d, () => VStack({ spacing: 8 }, [statusSection(d), noticeLine(), accountsSection(d), routingSection(i), usageSection(i), keysSection(d), testSection()]))]).padding(16);
  }
  function tabsLayout(d, i, setup) {
    const [chosen, setTab] = signal(null);
    const tab = () => chosen() ?? (setupPending(d) ? "setup" : "overview");
    const tabs = [
      ["overview", t("tab.overview", "Overview")],
      ["accounts", t("section.accounts", "Accounts")],
      ["keys", t("tab.keys", "Keys")],
      ["usage", t("section.usage", "Usage")],
      ["routing", t("tab.routing", "Routing")],
      ["setup", t("tab.setup", "Setup")]
    ];
    return VStack({ spacing: 10 }, [whenReachable(d, () => VStack({ spacing: 10 }, [
      choice(tabs, tab, setTab),
      Divider(),
      noticeLine(),
      () => {
        switch (tab()) {
          case "overview":
            return VStack({ spacing: 8 }, [statusSection(d), header(t("section.test", "Test request")), testBody()]);
          case "accounts":
            return accountsSection(d);
          case "keys":
            return keysSection(d);
          case "usage":
            return usageSection(i);
          case "routing":
            return routingSection(i);
          case "setup":
            return setup();
        }
      }
    ]))]).padding(16);
  }
  function summary(d) {
    return loaded(d.status, OP.status, (s) => {
      if (!s.signed_in)
        return Row({ title: t("problem.signedOut", "Sign in to cmux"), subtitle: t("section.signIn.sub", "to use CodeRouter"), symbol: "person.crop.circle", tint: "secondary" }).onTap(signIn);
      const accounts = d.accounts() ?? [];
      const healthy = accounts.filter(isHealthyAccount).length;
      const shared = accounts.filter((a) => a.visibility === "team").length;
      const keys = (d.keys() ?? []).filter((k) => !k.revoked).length;
      return VStack({ spacing: 0 }, [
        Row({
          title: s.scope?.kind === "team" ? s.scope.team_name : t("scope.personal", "Personal"),
          subtitle: `${healthWord(s.health)} · ${usageSummary(s.usage_today)}`,
          symbol: "arrow.triangle.branch",
          tint: healthTone(s.health)
        }).onTap(() => openPane("dashboard")).contextMenu([Button(t("action.runTest", "Run Test"), () => runTest()), Button(t("action.setUp", "Set Up CodeRouter"), () => onboard({ type: "restart" }, d.facts()))]),
        Row({
          title: accounts.length ? t("section.accountsCount", "{healthy} of {total} accounts ready", { healthy, total: accounts.length }) : t("section.noAccounts", "No accounts connected"),
          subtitle: s.scope?.kind === "team" && accounts.length ? t("section.sharedCount", "{n} shared with the team", { n: shared }) : null,
          symbol: healthy < accounts.length ? "exclamationmark.circle" : "person.crop.circle.badge.checkmark",
          tint: healthy < accounts.length ? "warning" : "secondary"
        }).onTap(() => openPane("dashboard")),
        keys ? Row({ title: t("section.keysCount", "{n} API keys", { n: keys }), symbol: "key", tint: "secondary" }).onTap(() => openPane("dashboard")) : null
      ]);
    });
  }
  function section(d) {
    const pending = computed(() => setupPending(d));
    return VStack({ spacing: 4 }, [
      () => {
        if (!pending())
          return null;
        if (variant() === "checklist")
          return checklist(d);
        return Row({ title: t("section.finishSetup", "Finish setting up"), subtitle: () => t("checklist.left", "{n} left", { n: remaining(progress(), d.facts()) }), symbol: "sparkles", tint: "accent", accessory: "chevron" }).onTap(() => openPane("onboarding"));
      },
      summary(d),
      () => pending() && variant() === "checklist" ? null : noticeLine()
    ]);
  }
  function statusItem(d) {
    const tone = () => d.status.problem() ? "tertiary" : healthTone(d.status()?.health);
    const text = () => {
      const s = d.status();
      if (d.status.problem() || !s)
        return "";
      if (!s.signed_in)
        return t("status.signedOut", "Signed out");
      if (s.health === "down")
        return t("health.down", "Down");
      return cmux.app.settings().statusShowsUsage === false ? "" : usageSummary(s.usage_today);
    };
    return HStack({ spacing: 5 }, [dot(tone), Text(text).font("caption").monospaced()]).paddingHorizontal(6).cornerRadius(6).hoverBackground("hover").help(() => `CodeRouter: ${healthWord(d.status()?.health)}`).onTap(() => openPane("dashboard")).contextMenu([
      Button(t("action.open", "Open CodeRouter"), () => openPane("dashboard")),
      Button(t("action.runTest", "Run Test"), () => runTest()),
      Button(t("action.setUp", "Set Up CodeRouter"), () => (onboard({ type: "restart" }, d.facts()), openPane("onboarding")))
    ]);
  }
  function prepare(ctx) {
    applyLocale(ctx);
    loadProgress();
  }
  function renderSection(ctx = {}) {
    prepare(ctx);
    return section(core());
  }
  function renderStatus(ctx = {}) {
    prepare(ctx);
    return statusItem(core(true));
  }
  function renderDashboard(ctx = {}) {
    prepare(ctx);
    const d = core();
    const i = insights();
    return VStack([() => variant() === "tabs" ? tabsLayout(d, i, () => page(d, 0)) : sectionsLayout(d, i)]);
  }
  function renderOnboarding(ctx = {}) {
    prepare(ctx);
    const d = core();
    return VStack([
      () => {
        switch (variant()) {
          case "wizard":
            return wizard(d);
          case "tabs":
            return page(d);
          default:
            return checklist(d).padding(16);
        }
      }
    ]);
  }
  async function open() {
    return { opened: await openPane("dashboard") };
  }
  async function connectAccount(args = {}) {
    let provider = args.provider;
    let name = provider ?? "";
    if (!provider) {
      const [detected, accounts] = await Promise.all([cmux.call(OP.detect, {}), cmux.call(OP.accounts, {})]);
      const best = recommend(detected, accounts)[0];
      if (!best)
        return { connected: false, reason: t("command.nothingToConnect", "Nothing new to connect on this Mac.") };
      provider = best.provider;
      name = best.name;
    }
    return { provider, connected: await connect(provider, name) };
  }
  async function createKey2(args = {}) {
    const created = await createKey(args.label ?? "");
    return created ? { id: created.key.id, label: created.key.label, prefix: created.key.prefix, shownBy: "cmux" } : { created: false };
  }
  async function runTest2() {
    return runTest();
  }
  async function startOnboarding() {
    await loadProgress();
    const [status, accounts] = await Promise.all([cmux.call(OP.status, {}).catch(() => {
      return;
    }), cmux.call(OP.accounts, {}).catch(() => {
      return;
    })]);
    const p = onboard({ type: "restart" }, factsOf(status, accounts, undefined, false));
    return { step: p.current, opened: await openPane("onboarding") };
  }
  async function cycleVariant2() {
    return { variant: await cycleVariant() };
  }
  globalThis.__cmuxAppExports = { ...exports_main };
})();
