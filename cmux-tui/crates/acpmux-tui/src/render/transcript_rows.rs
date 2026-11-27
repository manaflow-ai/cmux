//! A transcript rendered into rows (`transcript_rows`).

use super::*;

/// A queued prompt's note. It no longer says it "sends when the running turn ends", as the GUI's
/// queued row no longer does (cmux#45044; Leo: "it's not really useful to see ever"); the ⋯ marker
/// says queued, and the key that cancels it stays.
const QUEUED_NOTE: &str = "queued · Ctrl-x cancels it";

/// Render a transcript into rows at `width`. Every row starts after a
/// two-column gutter that holds the role or state marker, so text lines
/// up down the page. The transcript is a hierarchy of collapsibles: the
/// work of a turn (everything between your message and the turn's final
/// reply; the message and the reply themselves never hide), runs of
/// consecutive tool calls, and single tool calls or thoughts. `toggled`
/// holds the ones flipped from their default (work and groups open,
/// details closed); the thought being streamed is always open.
pub fn transcript_rows(
    t: &Transcript,
    width: usize,
    show_thoughts: bool,
    show_system: bool,
    toggled: &std::collections::HashSet<Toggle>,
    c: &Chrome,
) -> Vec<Row> {
    transcript_rows_range(
        t,
        width,
        show_thoughts,
        show_system,
        toggled,
        c,
        0..t.items.len(),
        true,
        None,
    )
}

pub(super) fn transcript_rows_range(
    t: &Transcript,
    width: usize,
    show_thoughts: bool,
    show_system: bool,
    toggled: &std::collections::HashSet<Toggle>,
    c: &Chrome,
    range: std::ops::Range<usize>,
    footer: bool,
    mut markdown: Option<&mut std::collections::HashMap<usize, Vec<Row>>>,
) -> Vec<Row> {
    let mut rows: Vec<Row> = Vec::new();
    let w = width;
    let running = t.status == "running";
    let last = t.items.len().saturating_sub(1);
    // The turn acpmux holds for capacity and continues itself: drawn calm, never red (GUI parity).
    let held = crate::capacity_wait::held_error(t);
    let is_open = |tg: Toggle, default_open: bool| default_open ^ toggled.contains(&tg);
    let group = |it: &Item| matches!(it, Item::Tool { .. } | Item::Permission { .. });
    // Visible items: lifecycle noise and silent turn ends never draw.
    let vis: Vec<usize> = range
        .filter(|&i| {
            let it = &t.items[i];
            if let Item::Permission { title, decided: Some(d), .. } = it {
                // "✓ Allowed  Write x" right under "✎ Write x" repeats the row.
                let echoes_tool =
                    i > 0 && matches!(&t.items[i - 1], Item::Tool { title: tt, .. } if tt == title);
                if d.starts_with("allow") && echoes_tool {
                    return false;
                }
            }
            (show_system || !is_system_noise(it))
                && !matches!(it, Item::TurnEnd { stop } if stop == "end_turn")
        })
        .collect();
    // An ended turn the person steered right before its end reads its work, the steer, then the
    // reply (Leo, 2026-11-25: "worked for above my message and then yours and then boom that's
    // it"); a running turn draws as it came.
    let (vis, late) = late_steers_last(t, vis, running);
    // Codex spacing: one plain blank row before every block. The user block
    // also carries a tinted blank row inside its band above and below.
    let after_user_block = false;
    let spacer = |rows: &mut Vec<Row>, i: usize, _after_user_block: bool| {
        if !rows.is_empty() {
            plain("", Style::default(), i, rows);
        }
    };
    // One tool or permission row (plus open details) at `indent`.
    let tool_rows = |rows: &mut Vec<Row>, i: usize, indent: &str| {
        let iw = width.saturating_sub(indent.len());
        match &t.items[i] {
            Item::Tool { title, kind, status, detail, .. } => {
                // Codex app: one muted line per activity, an icon for the
                // kind, paths shortened, red only when it failed. Details
                // open on click.
                let glyph = match kind.as_str() {
                    "read" => "≡",
                    "edit" => "✎",
                    "execute" => "$",
                    "search" => "⌕",
                    "fetch" => "↓",
                    "think" => "…",
                    "delete" | "move" => "⇄",
                    _ => "•",
                };
                let (gstyle, tstyle) = match status.as_str() {
                    "failed" => (Style::default().fg(c.error_fg), Style::default().fg(c.error_fg)),
                    "in_progress" | "pending" => (c.muted(), c.muted()),
                    _ => (c.dim(), c.muted()),
                };
                let open = !detail.is_empty() && is_open(Toggle::Item(i), false);
                // A diff names its files better than the harness's generic
                // "Editing files": "Edited calc.py".
                let files: Vec<String> = detail
                    .lines()
                    .filter_map(|l| l.strip_prefix("@@ "))
                    .map(|p| p.rsplit('/').next().unwrap_or(p).to_owned())
                    .collect();
                let shown = if !files.is_empty()
                    && (kind == "edit" || title.to_lowercase().contains("edit"))
                {
                    format!(
                        "{} {}",
                        if status == "completed" { "Edited" } else { "Editing" },
                        files.join(", ")
                    )
                } else {
                    shorten_tool_title(title)
                };
                let title_shown = truncate(&shown, iw.saturating_sub(4));
                let text = format!("{indent}{glyph} {title_shown}");
                let mut spans = vec![
                    Span::raw(indent.to_owned()),
                    Span::styled(format!("{glyph} "), gstyle),
                    Span::styled(title_shown, tstyle),
                ];
                let counts = acpmux::transcript::diff_counts(detail);
                if let Some((plus, minus)) = counts {
                    spans.push(Span::styled(
                        format!("  +{plus}"),
                        Style::default().fg(c.diff_add_fg),
                    ));
                    spans.push(Span::styled(
                        format!(" -{minus}"),
                        Style::default().fg(c.diff_del_fg),
                    ));
                }
                if !detail.is_empty() {
                    spans.push(Span::styled(if open { "  ▾" } else { "  ›" }, c.dim()));
                }
                rows.push(Row {
                    line: Line::from(spans),
                    text,
                    item: i,
                    toggle: if detail.is_empty() { None } else { Some(Toggle::Item(i)) },
                });
                if open && counts.is_some() {
                    // Diff lines keep their prefix colors and are not wrapped.
                    for l in detail.lines() {
                        let style = match l.chars().next() {
                            Some('+') => Style::default().fg(c.diff_add_fg),
                            Some('-') => Style::default().fg(c.diff_del_fg),
                            Some('@') => c.muted(),
                            _ => c.dim(),
                        };
                        let text = format!("{indent}  {}", truncate(l, iw.saturating_sub(3)));
                        rows.push(Row {
                            line: Line::from(Span::styled(text.clone(), style)),
                            text,
                            item: i,
                            toggle: None,
                        });
                    }
                } else if open {
                    wrap(detail, iw.saturating_sub(2), c.dim(), &format!("{indent}  "), i, rows);
                }
            }
            Item::Permission { title, decided, .. } => {
                // Codex app wording: the request while it waits, the answer after.
                let shown = shorten_tool_title(title);
                let (text, style) = match decided.as_deref() {
                    Some(d) if d.starts_with("allow") => {
                        (format!("{indent}✓ Allowed  {shown}"), c.dim())
                    }
                    Some(d) if d.starts_with("reject") => {
                        (format!("{indent}✗ Rejected  {shown}"), c.dim())
                    }
                    Some(_) => (format!("{indent}– Cancelled  {shown}"), c.dim()),
                    None => (
                        format!("{indent}? Needs permission  {shown}"),
                        Style::default().fg(c.attention_fg),
                    ),
                };
                plain(&text, style, i, rows);
            }
            _ => {}
        }
    };

    let mut k = 0usize;
    let mut turn_open = true;
    // When a turn's work is collapsed, rendering resumes at this item (the
    // turn's final reply, or the next user message).
    let mut reopen_at: Option<usize> = None;
    while k < vis.len() {
        let i = vis[k];
        if reopen_at == Some(i) {
            turn_open = true;
            reopen_at = None;
        }
        let item = &t.items[i];
        match item {
            Item::User { text, steer, queued } => {
                k += 1;
                turn_open = true;
                reopen_at = None;
                spacer(&mut rows, i, false);
                // Timestamps share the transcript content margin.
                if let Some(at) = t.user_at.get(&i) {
                    let label = when_label(*at);
                    let text = format!("{GUTTER}{label}");
                    rows.push(Row {
                        line: Line::from(Span::styled(text.clone(), c.dim())),
                        text,
                        item: i,
                        toggle: None,
                    });
                    plain("", Style::default(), i, &mut rows);
                }
                // Keep user text on the same left margin as assistant text,
                // with its role marker in the gutter and a tinted background.
                let bg = Style::default().bg(c.user_bg);
                let style = if *queued { c.dim().bg(c.user_bg) } else { bg.fg(c.status_fg) };
                let marker = if *steer {
                    "» "
                } else if *queued {
                    "⋯ "
                } else {
                    "❯ "
                };
                let marker_style = bg.fg(c.status_dim_fg).add_modifier(Modifier::BOLD);
                let bubble_w = if width < 50 { width } else { (width * 7 / 10).max(40).min(width) };
                let inner_w = bubble_w.saturating_sub(4);
                let mut body: Vec<Row> = Vec::new();
                wrap(text, inner_w, style, "", i, &mut body);
                if *queued {
                    plain(QUEUED_NOTE, c.dim().bg(c.user_bg), i, &mut body);
                }
                let bubble_row = |content: Vec<Span<'static>>, used: usize, text: String| -> Row {
                    let mut spans = Vec::new();
                    spans.extend(content);
                    spans.push(Span::styled(" ".repeat(bubble_w.saturating_sub(used)), bg));
                    Row { line: Line::from(spans), text, item: i, toggle: None }
                };
                rows.push(bubble_row(vec![], 0, String::new()));
                for (n, r) in body.into_iter().enumerate() {
                    let m = if n == 0 { marker } else { "  " };
                    let content = r.text.clone();
                    let used = 2 + content.width();
                    let spans = vec![
                        Span::styled(m.to_owned(), if n == 0 { marker_style } else { bg }),
                        Span::styled(
                            content.clone(),
                            if r.line.spans.len() > 1 {
                                r.line.spans[1].style.bg(c.user_bg)
                            } else {
                                style
                            },
                        ),
                    ];
                    rows.push(bubble_row(spans, used, format!("{m}{content}")));
                }
                rows.push(bubble_row(vec![], 0, String::new()));
                let _ = after_user_block;
                // The turn's work: everything visible between this message
                // and the final reply. Two or more blocks get a handle row
                // that collapses them all; one block collapses on its own.
                let next_user = t.items[i + 1..]
                    .iter()
                    .position(|x| matches!(x, Item::User { queued: false, .. }))
                    .map(|p| i + 1 + p)
                    .unwrap_or(t.items.len());
                let turn_live = running && next_user == t.items.len();
                // Positions in drawing order (`vis`), which `late_steers_last` may have reordered.
                let next_pos = (k..vis.len())
                    .find(|&p| matches!(t.items[vis[p]], Item::User { queued: false, .. }))
                    .unwrap_or(vis.len());
                // While the turn runs there is no final reply yet: every block
                // is work and the handle reads "Working for …". Above a late steer
                // the reply comes after the steer: everything here is work.
                let final_reply = if turn_live
                    || vis.get(next_pos).is_some_and(|j| late.contains(j))
                {
                    None
                } else {
                    (k..next_pos).rev().find(|&p| matches!(t.items[vis[p]], Item::Assistant { .. }))
                };
                let work_end = final_reply.unwrap_or(next_pos);
                let work: Vec<usize> = vis[k..work_end].to_vec();
                let mut blocks = 0usize;
                let mut tools = 0usize;
                let mut commands = 0usize;
                let mut failed_tools = 0usize;
                let mut thoughts = 0usize;
                let mut prev_group = false;
                for &j in &work {
                    match &t.items[j] {
                        Item::Tool { title, kind, status, .. } => {
                            tools += 1;
                            if matches!(kind.as_str(), "execute" | "terminal" | "shell")
                                || title.to_ascii_lowercase().contains("command")
                                || title.to_ascii_lowercase().contains("bash")
                                || title.to_ascii_lowercase().contains("shell")
                            {
                                commands += 1;
                            }
                            if status == "failed" {
                                failed_tools += 1;
                            }
                            if !prev_group {
                                blocks += 1;
                            }
                            prev_group = true;
                        }
                        Item::Permission { .. } => {
                            if !prev_group {
                                blocks += 1;
                            }
                            prev_group = true;
                        }
                        Item::Thought { .. } => {
                            thoughts += 1;
                            blocks += 1;
                            prev_group = false;
                        }
                        Item::Assistant { .. } => {
                            blocks += 1;
                            prev_group = false;
                        }
                        // Keep a failed turn's notice visible after the work
                        // summary folds; the error is the useful result.
                        Item::Error { .. } => {}
                        _ => {
                            blocks += 1;
                            prev_group = false;
                        }
                    }
                }
                // A late steer's rows are the reply: nothing under it folds.
                if blocks >= 1 && !late.contains(&i) {
                    // Finished work starts folded; a live turn stays open so
                    // its activity is visible while the agent is working.
                    let open = is_open(Toggle::Turn(i), turn_live);
                    // Codex app: "Worked for 1m 7s ›" (collapsed) or "Worked for 1m 7s ▾".
                    let span = t.turn_span(i);
                    let edited_files = work
                        .iter()
                        .filter_map(|&j| match &t.items[j] {
                            Item::Tool { detail, .. } => Some(detail),
                            _ => None,
                        })
                        .flat_map(|detail| {
                            detail
                                .lines()
                                .filter_map(|line| line.strip_prefix("@@ "))
                                .map(|path| path.to_owned())
                        })
                        .collect::<std::collections::HashSet<_>>()
                        .len();
                    let mut label = match span {
                        Some((start, Some(end))) => {
                            format!("Worked for {}", duration_label(end.saturating_sub(start)))
                        }
                        Some((start, None))
                            if t.turn_times.last().map(|x| x.0 == i).unwrap_or(false)
                                && t.status != "ready"
                                && t.status != "idle" =>
                        {
                            format!(
                                "Working for {}",
                                duration_label(now_ms().saturating_sub(start))
                            )
                        }
                        _ => "Worked".to_owned(),
                    };
                    if tools > 0 {
                        label.push_str(&format!(
                            " · {tools} step{}",
                            if tools == 1 { "" } else { "s" }
                        ));
                    }
                    if commands > 0 {
                        label.push_str(&format!(
                            " · {commands} command{}",
                            if commands == 1 { "" } else { "s" }
                        ));
                    }
                    if thoughts > 0 {
                        label.push_str(&format!(
                            " · {thoughts} thought{}",
                            if thoughts == 1 { "" } else { "s" }
                        ));
                    }
                    if edited_files > 0 {
                        label.push_str(&format!(
                            " · {edited_files} file{} edited",
                            if edited_files == 1 { "" } else { "s" }
                        ));
                    }
                    if failed_tools > 0 {
                        label.push_str(&format!(" · {failed_tools} failed"));
                    }
                    spacer(&mut rows, i, false);
                    let text = format!("{label}  {}", if open { "▾" } else { "›" });
                    rows.push(Row {
                        line: Line::from(vec![
                            Span::styled(label.to_string(), c.muted()),
                            Span::styled(format!("  {}", if open { "▾" } else { "›" }), c.dim()),
                        ]),
                        text,
                        item: i,
                        toggle: Some(Toggle::Turn(i)),
                    });
                    // Codex app: a hairline under the handle.
                    rows.push(Row {
                        line: Line::from(Span::styled(
                            "─".repeat(w).to_string(),
                            Style::default().fg(c.composer_border_fg),
                        )),
                        text: String::new(),
                        item: i,
                        toggle: None,
                    });
                    // "Edited 2 files  +21 -2": the turn's file edits, summed, visible even when folded.
                    let mut files: Vec<String> = Vec::new();
                    let (mut plus, mut minus) = (0usize, 0usize);
                    for &j in &work {
                        if let Item::Tool { detail, .. } = &t.items[j]
                            && let Some((p, m)) = acpmux::transcript::diff_counts(detail)
                        {
                            plus += p;
                            minus += m;
                            for f in detail
                                .lines()
                                .filter_map(|l| l.strip_prefix("@@ "))
                                .map(|p| p.rsplit('/').next().unwrap_or(p).to_owned())
                            {
                                if !files.contains(&f) {
                                    files.push(f);
                                }
                            }
                        }
                    }
                    if !files.is_empty() {
                        let label = format!(
                            "✎ Edited {} file{}  ",
                            files.len(),
                            if files.len() == 1 { "" } else { "s" }
                        );
                        let names =
                            truncate(&files.join(", "), w.saturating_sub(label.width() + 14));
                        let text = format!("{label}{names}  +{plus} -{minus}");
                        rows.push(Row {
                            line: Line::from(vec![
                                Span::styled(label, c.muted()),
                                Span::styled(names, c.dim()),
                                Span::styled(
                                    format!("  +{plus}"),
                                    Style::default().fg(c.diff_add_fg),
                                ),
                                Span::styled(
                                    format!(" -{minus}"),
                                    Style::default().fg(c.diff_del_fg),
                                ),
                            ]),
                            text,
                            item: i,
                            toggle: None,
                        });
                    }
                    if !open {
                        turn_open = false;
                        reopen_at = vis.get(work_end).copied();
                    }
                }
                continue;
            }
            it if group(it) => {
                let start_k = k;
                while k < vis.len() && group(&t.items[vis[k]]) {
                    k += 1;
                }
                if !turn_open {
                    continue;
                }
                let members = &vis[start_k..k];
                spacer(&mut rows, i, after_user_block);
                let tools: Vec<usize> = members
                    .iter()
                    .copied()
                    .filter(|&m| matches!(t.items[m], Item::Tool { .. }))
                    .collect();
                if tools.len() >= 2 {
                    let g = Toggle::Group(tools[0]);
                    let open = is_open(g, true);
                    let names: Vec<String> = tools
                        .iter()
                        .take(6)
                        .map(|&m| match &t.items[m] {
                            Item::Tool { title, .. } => {
                                title.split_whitespace().next().unwrap_or("tool").to_owned()
                            }
                            _ => String::new(),
                        })
                        .collect();
                    let done = tools.iter().filter(|&&m| matches!(&t.items[m], Item::Tool { status, .. } if status == "completed")).count();
                    let failed = tools.iter().filter(|&&m| matches!(&t.items[m], Item::Tool { status, .. } if status == "failed")).count();
                    let state = if failed > 0 {
                        format!(" · {failed} failed")
                    } else if done < tools.len() {
                        format!(" · {done}/{} done", tools.len())
                    } else {
                        String::new()
                    };
                    let text = format!(
                        "{} steps · {}{state}  {}",
                        tools.len(),
                        names.join(", "),
                        if open { "▾" } else { "›" }
                    );
                    rows.push(Row {
                        line: Line::from(vec![
                            Span::styled(format!("{} steps", tools.len()), c.muted()),
                            Span::styled(format!(" · {}{state}", names.join(", ")), c.dim()),
                            Span::styled(format!("  {}", if open { "▾" } else { "›" }), c.dim()),
                        ]),
                        text,
                        item: tools[0],
                        toggle: Some(g),
                    });
                    if open {
                        for &m in members {
                            tool_rows(&mut rows, m, "    ");
                        }
                    }
                } else {
                    for &m in members {
                        tool_rows(&mut rows, m, "");
                    }
                }
            }
            _ => {
                k += 1;
                if !turn_open {
                    continue;
                }
                spacer(&mut rows, i, after_user_block);
                match item {
                    Item::Assistant { text } => {
                        if let Some(cache) = markdown.as_deref_mut() {
                            let rendered = cache.entry(i).or_insert_with(|| {
                                let mut rows = Vec::new();
                                super::super::markdown::render(
                                    text,
                                    width,
                                    "",
                                    Style::default(),
                                    c,
                                    i,
                                    &mut rows,
                                );
                                rows
                            });
                            rows.extend(rendered.iter().cloned());
                        } else {
                            super::super::markdown::render(
                                text,
                                width,
                                "",
                                Style::default(),
                                c,
                                i,
                                &mut rows,
                            );
                        }
                    }
                    Item::Thought { text } => {
                        let live = running && i == last;
                        let open = live || is_open(Toggle::Item(i), show_thoughts);
                        let n = text.chars().count();
                        let first_line =
                            text.lines().find(|l| !l.trim().is_empty()).unwrap_or("").trim();
                        let _ = n;
                        let summary = first_line.trim_matches('*').trim();
                        if live {
                            // Codex app: one shimmering line with the latest
                            // sentence while it streams; a click opens the rest.
                            let latest = text
                                .lines()
                                .rev()
                                .find(|l| !l.trim().is_empty())
                                .unwrap_or("")
                                .trim()
                                .trim_matches('*')
                                .trim();
                            let mut spans = vec![Span::raw("")];
                            spans.extend(super::super::shimmer::spans(
                                "Thinking",
                                c.shimmer_base,
                                c.shimmer_bright,
                            ));
                            if !latest.is_empty() {
                                spans.push(Span::styled(
                                    format!("  {}", truncate(latest, w.saturating_sub(12))),
                                    c.dim().add_modifier(Modifier::ITALIC),
                                ));
                            }
                            rows.push(Row {
                                line: Line::from(spans),
                                text: format!("Thinking  {latest}"),
                                item: i,
                                toggle: Some(Toggle::Item(i)),
                            });
                            if is_open(Toggle::Item(i), false) {
                                wrap(
                                    text,
                                    w,
                                    c.dim().add_modifier(Modifier::ITALIC),
                                    "",
                                    i,
                                    &mut rows,
                                );
                            }
                        } else if open {
                            header_row("Thought  ▾", c.muted_fg, i, Toggle::Item(i), &mut rows);
                            wrap(text, w, c.dim().add_modifier(Modifier::ITALIC), "", i, &mut rows);
                        } else {
                            let shown = truncate(summary, w.saturating_sub(14));
                            let text_row = format!("Thought  {shown}  ›");
                            rows.push(Row {
                                line: Line::from(vec![
                                    Span::raw(""),
                                    Span::styled("Thought  ", c.muted()),
                                    Span::styled(shown, c.dim().add_modifier(Modifier::ITALIC)),
                                    Span::styled("  ›", c.dim()),
                                ]),
                                text: text_row,
                                item: i,
                                toggle: Some(Toggle::Item(i)),
                            });
                        }
                    }
                    Item::Status { text } => plain(&format!("-- {text}"), c.dim(), i, &mut rows),
                    Item::TurnEnd { stop } => plain(&format!("-- {stop}"), c.dim(), i, &mut rows),
                    Item::Error { text } => {
                        // Codex app: a rounded notice card with an icon.
                        let border = Style::default().fg(c.composer_border_fg);
                        let cw = width.max(12);
                        let inner = cw.saturating_sub(6);
                        let mut body: Vec<Row> = Vec::new();
                        let calm = held == Some(i);
                        // A usage limit that names its reset leads with when (cmux#52296); any
                        // other failure a rule knows leads with the GUI's plain sentence (#41975).
                        let reset = if calm {
                            None
                        } else {
                            crate::usage_reset::note(text)
                                .or_else(|| crate::failure_copy::sentence_for(text, None))
                        };
                        let mut first = 1;
                        if calm {
                            let note =
                                format!("Waiting for capacity · {}", crate::capacity_wait::GOES_ON);
                            wrap(&note, inner, Style::default().fg(c.status_fg), "", i, &mut body);
                            first = body.len();
                            wrap(text, inner, c.dim(), "", i, &mut body);
                        } else if let Some(note) = reset.as_deref() {
                            wrap(note, inner, Style::default().fg(c.status_fg), "", i, &mut body);
                            first = body.len();
                            wrap(text, inner, c.dim(), "", i, &mut body);
                        } else {
                            wrap(text, inner, Style::default().fg(c.status_fg), "", i, &mut body);
                        }
                        rows.push(Row {
                            line: Line::from(Span::styled(
                                format!("╭{}╮", "─".repeat(cw - 2)),
                                border,
                            )),
                            text: String::new(),
                            item: i,
                            toggle: None,
                        });
                        for (n, r) in body.into_iter().enumerate() {
                            let content = r.text.clone();
                            let icon = match (n, calm) {
                                (0, true) => "◷ ",
                                (0, false) => "✗ ",
                                _ => "  ",
                            };
                            let icon_fg = if calm { c.attention_fg } else { c.error_fg };
                            let text_style = if n >= first && (calm || reset.is_some()) {
                                c.dim()
                            } else {
                                Style::default().fg(c.status_fg)
                            };
                            let pad = inner.saturating_sub(content.width());
                            rows.push(Row {
                                line: Line::from(vec![
                                    Span::styled("│ ".to_owned(), border),
                                    Span::styled(
                                        icon.to_owned(),
                                        Style::default().fg(icon_fg).add_modifier(Modifier::BOLD),
                                    ),
                                    Span::styled(content.clone(), text_style),
                                    Span::raw(" ".repeat(pad)),
                                    Span::styled(" │".to_owned(), border),
                                ]),
                                text: format!("  {icon}{content}"),
                                item: i,
                                toggle: None,
                            });
                        }
                        rows.push(Row {
                            line: Line::from(Span::styled(
                                format!("╰{}╯", "─".repeat(cw - 2)),
                                border,
                            )),
                            text: String::new(),
                            item: i,
                            toggle: None,
                        });
                    }
                    Item::Stderr { text } => plain(
                        &format!("stderr: {}", truncate(text, w.saturating_sub(8))),
                        c.dim(),
                        i,
                        &mut rows,
                    ),
                    _ => {}
                }
            }
        }
    }
    // Queued prompts dock at the bottom, under the running turn, until each is delivered and
    // joins the transcript where it arrived (`Transcript::queue`). They are no item: their rows
    // name the index past the last one, which no fold or copy resolves.
    let docked: &[acpmux::transcript::QueuedPrompt] = if footer { &t.queue } else { &[] };
    for q in docked {
        let i = t.items.len();
        {
            let text = &q.text;
            spacer(&mut rows, i, false);
            let bg = Style::default().bg(c.user_bg);
            let style = c.dim().bg(c.user_bg);
            let bubble_w = if width < 50 { width } else { (width * 7 / 10).max(40).min(width) };
            let inner_w = bubble_w.saturating_sub(4);
            let mut body: Vec<Row> = Vec::new();
            wrap(text, inner_w, style, "", i, &mut body);
            plain(QUEUED_NOTE, c.dim().bg(c.user_bg), i, &mut body);
            let bubble_row = |content: Vec<Span<'static>>, used: usize, text: String| -> Row {
                let mut spans = Vec::new();
                spans.extend(content);
                spans.push(Span::styled(" ".repeat(bubble_w.saturating_sub(used)), bg));
                Row { line: Line::from(spans), text, item: i, toggle: None }
            };
            rows.push(bubble_row(vec![], 0, String::new()));
            for (n, r) in body.into_iter().enumerate() {
                let m = if n == 0 { "⋯ " } else { "  " };
                let content = r.text.clone();
                let used = 2 + content.width();
                rows.push(bubble_row(
                    vec![
                        Span::styled(
                            m.to_owned(),
                            bg.fg(c.status_dim_fg).add_modifier(Modifier::BOLD),
                        ),
                        Span::styled(content.clone(), style),
                    ],
                    used,
                    format!("{m}{content}"),
                ));
            }
            rows.push(bubble_row(vec![], 0, String::new()));
        }
    }
    if running && footer {
        plain("", Style::default(), usize::MAX, &mut rows);
        rows.push(working_row(t, c));
    } else if footer && let Some(wait) = t.capacity_wait.as_ref() {
        plain("", Style::default(), usize::MAX, &mut rows);
        rows.push(capacity_row(wait, c));
    }
    rows
}

/// The drawing order of `vis` with each ended turn's late steers moved under its work and over
/// its reply (port of webviews `turns.ts` `lateSteersLast`). From a turn's end back, a steer with
/// no tool call started after it is late; from the first one, the agent's text right above it
/// joins the region, which reads its other rows, then the steers, then the agent's text. Only when
/// the turn's final reply is in that region. Returns the order and the late steers' items.
pub(super) fn late_steers_last(
    t: &Transcript,
    mut vis: Vec<usize>,
    running: bool,
) -> (Vec<usize>, std::collections::HashSet<usize>) {
    let mut late = std::collections::HashSet::new();
    let prompt = |i: usize| matches!(t.items[i], Item::User { queued: false, steer: false, .. });
    let steer = |i: usize| matches!(t.items[i], Item::User { queued: false, steer: true, .. });
    let text = |i: usize| matches!(t.items[i], Item::Assistant { .. });
    let mut start = 0usize;
    while start < vis.len() {
        let stop = (start + 1..vis.len()).find(|&p| prompt(vis[p])).unwrap_or(vis.len());
        let turn = start;
        start = stop;
        if !prompt(vis[turn]) {
            continue;
        }
        let live = running
            && !t.items[vis[turn] + 1..]
                .iter()
                .any(|x| matches!(x, Item::User { queued: false, steer: false, .. }));
        if live {
            continue;
        }
        // The turn's end: its footer (a stop the turn shows) or a queued message waiting under it.
        let end = (turn + 1..stop)
            .find(|&p| {
                matches!(t.items[vis[p]], Item::TurnEnd { .. } | Item::User { queued: true, .. })
            })
            .unwrap_or(stop);
        let mut first = None;
        for p in (turn + 1..end).rev() {
            match &t.items[vis[p]] {
                Item::Tool { .. } => break,
                _ if steer(vis[p]) => first = Some(p),
                _ => {}
            }
        }
        let Some(first) = first else { continue };
        let mut from = first;
        while from > turn + 1 && text(vis[from - 1]) {
            from -= 1;
        }
        let Some(answer) = (turn + 1..end).rev().find(|&p| text(vis[p])) else { continue };
        if answer < from {
            continue;
        }
        let region = &vis[from..end];
        let steers: Vec<usize> = region.iter().copied().filter(|&i| steer(i)).collect();
        let mut reordered: Vec<usize> =
            region.iter().copied().filter(|&i| !steer(i) && !text(i)).collect();
        reordered.extend(&steers);
        reordered.extend(region.iter().copied().filter(|&i| text(i)));
        if reordered != region {
            late.extend(steers);
            vis.splice(from..end, reordered);
        }
    }
    (vis, late)
}

/// The footer while acpmux waits out a capacity cut: the GUI's calm line, counting down.
pub(super) fn capacity_row(wait: &serde_json::Value, c: &Chrome) -> Row {
    let label = crate::capacity_wait::line(wait, now_ms());
    let line = Line::from(vec![
        Span::styled("◷ ".to_owned(), Style::default().fg(c.attention_fg)),
        Span::styled(label.clone(), c.muted()),
    ]);
    Row { line, text: format!("◷ {label}"), item: usize::MAX, toggle: None }
}

pub(super) fn working_row(t: &Transcript, c: &Chrome) -> Row {
    // Codex-style persistent footer: it remains visible while a tool or
    // thought streams, and carries the normalized activity plus the
    // interrupt affordance so the user never has to infer whether work
    // is still live from the last transcript row.
    let elapsed = match t.turn_times.last() {
        Some((_, start, None)) => duration_label(now_ms().saturating_sub(*start)).to_string(),
        _ => "…".to_owned(),
    };
    let mut label = format!("Working ({elapsed} · Esc to interrupt)");
    if let Some(activity) = t.activity.as_deref().filter(|s| !s.is_empty()) {
        label.push_str(" · ");
        label.push_str(activity);
    }
    if t.active_terminals > 0 {
        label.push_str(&format!(
            " · {} background terminal{}",
            t.active_terminals,
            if t.active_terminals == 1 { "" } else { "s" }
        ));
    } else if t.active_tools > 0 {
        label.push_str(&format!(
            " · {} active tool{}",
            t.active_tools,
            if t.active_tools == 1 { "" } else { "s" }
        ));
    }
    if let Some(wait) = t.subagent_wait(now_ms()) {
        label.push_str(" · ");
        label.push_str(&wait);
    }
    let queued = t.queue.len();
    if queued > 0 {
        label.push_str(&format!(" · {} queued", queued));
    }
    let mut spans = vec![Span::raw("")];
    spans.extend(super::super::shimmer::spans(&label, c.shimmer_base, c.shimmer_bright));
    let note = t.note.as_deref().map(|n| format!("  {n}")).unwrap_or_default();
    if !note.is_empty() {
        spans.push(Span::styled(note.clone(), c.dim()));
    }
    Row { line: Line::from(spans), text: format!("{label}{note}"), item: usize::MAX, toggle: None }
}

#[cfg(test)]
#[path = "transcript_rows_late_steer_tests.rs"]
mod late_steer_tests;
