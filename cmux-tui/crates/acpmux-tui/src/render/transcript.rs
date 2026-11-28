//! Part of the TUI renderer; see `render/mod.rs`.

use super::*;

pub(super) fn draw_transcript(f: &mut ratatui::Frame, area: Rect, app: &mut App) {
    let empty = app
        .selected_id()
        .and_then(|id| app.transcripts.get(&id))
        .map(|t| t.items.is_empty() && t.status != "running")
        .unwrap_or(true);
    if empty {
        app.rows_cache.clear();
        app.row_meta.clear();
        app.transcript_hitboxes.clear();
        app.transcript_cache = TranscriptCache::default();
    }
    let c = app.chrome;
    let buf = f.buffer_mut();
    fill(buf, area, Style::default());
    // Title row: name, status, and token usage. Settings live under the
    // composer.
    let title_y = area.y;
    let name = {
        let raw = app.selected_session().map(session_title).unwrap_or_else(|| app.selected_name());
        let peer = app
            .selected_session()
            .and_then(|s| s.get("peer").and_then(Value::as_str))
            .map(str::to_owned);
        let stripped = match peer {
            Some(p) => raw.strip_prefix(&format!("{p}/")).map(str::to_owned).unwrap_or(raw),
            None => raw,
        };
        truncate(&stripped, 64)
    };
    let (status, mode, model) = app
        .selected_id()
        .and_then(|id| app.transcripts.get(&id))
        .map(|t| {
            (
                t.status.clone(),
                t.mode.clone().unwrap_or_default(),
                t.model.clone().unwrap_or_default(),
            )
        })
        .unwrap_or_default();
    let usage = app
        .selected_id()
        .and_then(|id| app.transcripts.get(&id))
        .and_then(|t| t.usage)
        .map(|(u, s)| {
            if s > 0 {
                format!("{}k / {}k", u / 1000, s / 1000)
            } else {
                format!("{}k tokens", u / 1000)
            }
        })
        .unwrap_or_default();
    {
        // Codex app header: "▢ project  ›  title", status only when it
        // needs attention, token use at the right edge.
        let buf = f.buffer_mut();
        let project = app
            .selected_session()
            .and_then(|s| {
                let cwd = s.get("cwd").and_then(Value::as_str)?;
                let base = project_label(cwd);
                Some(match s.get("peer").and_then(Value::as_str) {
                    Some(p) => format!("{p} · {base}"),
                    None => base,
                })
            })
            .or_else(|| app.draft().map(|d| project_label(&d.cwd)))
            .unwrap_or_default();
        let mut x = area.x + 2;
        let right = area.x + area.width;
        let put = |buf: &mut Buffer, x: &mut u16, text: &str, style: Style| {
            let w = (text.width() as u16).min(right.saturating_sub(*x));
            if w > 0 {
                buf.set_stringn(*x, title_y, text, w as usize, style);
                *x += w;
            }
        };
        if !project.is_empty() {
            let project_start = x;
            put(buf, &mut x, "▢ ", c.dim());
            put(buf, &mut x, &project, c.muted());
            let project_rect = Rect {
                x: project_start,
                y: title_y,
                width: x.saturating_sub(project_start),
                height: 1,
            };
            if project_rect.width > 2 {
                app.buttons.push((project_rect, ButtonAction::EditDirectory));
            }
            put(buf, &mut x, "  ›  ", c.dim());
        }
        let name_style = if app.focus == Focus::Transcript && matches!(app.overlay, Overlay::None) {
            Style::default().fg(c.border_active_fg).add_modifier(Modifier::BOLD)
        } else {
            Style::default().add_modifier(Modifier::BOLD)
        };
        put(buf, &mut x, &name, name_style);
        let attention =
            matches!(status.as_str(), "waiting" | "disconnected" | "unreachable" | "closed");
        if attention {
            let word = match status.as_str() {
                "waiting" => "needs permission",
                other => other,
            };
            put(buf, &mut x, &format!("   {word}"), status_fg(&c, &status));
        }
        let uw = usage.width() as u16;
        if !usage.is_empty() && x + uw + 2 < right {
            buf.set_stringn(right - uw - 2, title_y, &usage, uw as usize, c.dim());
        }
        let _ = (&mode, &model);
    }
    let hover = app.hover;
    let buf = f.buffer_mut();
    let inner = app.transcript_inner();
    if let Some(d) = app.draft() {
        let mut buttons = Vec::new();
        // Codex app: a centered headline naming the project, the settings
        // as one muted line under it. The composer below is where to type.
        let project = project_label(&d.cwd);
        let headline = format!("What should we build in {project}?");
        let effort = d
            .effort
            .as_deref()
            .filter(|e| !e.is_empty() && *e != "default")
            .map(|e| format!("  ·  {}", effort_label(e)))
            .unwrap_or_default();
        let top = inner.y + inner.height / 3;
        let center = |buf: &mut Buffer, y: u16, text: &str, style: Style| {
            if y < inner.y + inner.height {
                let w = text.width().min(inner.width as usize);
                let x = inner.x + (inner.width as usize - w) as u16 / 2;
                buf.set_stringn(x, y, text, w, style);
            }
        };
        center(buf, top, &headline, Style::default().add_modifier(Modifier::BOLD));
        if top < inner.y + inner.height {
            let width = headline.width().min(inner.width as usize) as u16;
            let hx = inner.x + inner.width.saturating_sub(width) / 2;
            buttons.push((Rect { x: hx, y: top, width, height: 1 }, ButtonAction::DraftDirectory));
        }
        let settings_y = top + 2;
        let parts = [
            (
                format!(
                    "{}{}",
                    d.peer.as_deref().map(|p| format!("{p} / ")).unwrap_or_default(),
                    d.harness
                ),
                ButtonAction::DraftHarness,
            ),
            (
                d.model
                    .as_deref()
                    .map(model_label)
                    .unwrap_or_else(|| "default model".to_owned())
                    .to_string(),
                ButtonAction::DraftModel,
            ),
            (
                if effort.is_empty() {
                    String::new()
                } else {
                    effort.trim_start_matches("  ·  ").to_owned()
                },
                ButtonAction::DraftEffort,
            ),
            (crate::render::policy_label(&d.policy).0, ButtonAction::DraftPolicy),
        ];
        let mut labels = Vec::new();
        for (label, action) in parts.iter() {
            if label.is_empty() {
                continue;
            }
            if !labels.is_empty() {
                labels.push((" · ".to_owned(), None));
            }
            labels.push((label.clone(), Some(action.clone())));
        }
        let settings_w =
            labels.iter().map(|(s, _)| s.width()).sum::<usize>().min(inner.width as usize) as u16;
        let mut sx = inner.x + (inner.width.saturating_sub(settings_w)) / 2;
        for (label, action) in labels {
            let w = label.width().min((inner.x + inner.width).saturating_sub(sx) as usize) as u16;
            if w == 0 || settings_y >= inner.y + inner.height {
                break;
            }
            let r = Rect { x: sx, y: settings_y, width: w, height: 1 };
            let hot = action.is_some()
                && hover
                    .map(|(x, y)| y == settings_y && x >= r.x && x < r.x + r.width)
                    .unwrap_or(false);
            let style = if hot {
                Style::default().bg(c.status_active_bg).fg(c.status_active_fg)
            } else {
                c.muted()
            };
            buf.set_stringn(sx, settings_y, &label, w as usize, style);
            if let Some(a) = action {
                buttons.push((r, a));
            }
            sx += w;
        }
        center(buf, top + 4, "Type below and press Enter to start · Esc discards", c.dim());
        let mut y = top + 6;
        if d.creating {
            let label = format!("Starting {}…", d.harness);
            let w = label.width().min(inner.width as usize);
            let x = inner.x + (inner.width as usize - w) as u16 / 2;
            let spans = crate::shimmer::spans(&label, c.shimmer_base, c.shimmer_bright);
            f_render(
                buf,
                Paragraph::new(Line::from(spans)),
                Rect { x, y, width: w as u16, height: 1 },
            );
            y += 1;
        }
        for e in &d.errors {
            if y >= inner.y + inner.height {
                break;
            }
            buf.set_stringn(
                inner.x,
                y,
                format!("  ✗ {e}"),
                inner.width as usize,
                Style::default().fg(c.error_fg),
            );
            y += 1;
        }
        app.buttons.extend(buttons);
        return;
    }
    let Some(id) = app.selected_id() else {
        let top = inner.y + inner.height / 3;
        let center = |buf: &mut Buffer, y: u16, text: &str, style: Style| {
            if y < inner.y + inner.height {
                let w = text.width().min(inner.width as usize);
                let x = inner.x + (inner.width as usize - w) as u16 / 2;
                buf.set_stringn(x, y, text, w, style);
            }
        };
        center(buf, top, "What should we build?", Style::default().add_modifier(Modifier::BOLD));
        center(
            buf,
            top + 2,
            "Ctrl-t starts a session: pick a harness, name it, choose a directory",
            c.muted(),
        );
        center(
            buf,
            top + 3,
            &format!("?  every key        {}  every command", app.palette_prefix),
            c.dim(),
        );
        center(buf, top + 5, "From a shell:  acpmux new -m claude -n my-task", c.dim());
        return;
    };
    let cwd = app
        .selected_session()
        .and_then(|s| s.get("cwd").and_then(Value::as_str))
        .unwrap_or("")
        .to_owned();
    let wait = crate::capacity_wait::of_row(app.selected_session());
    let Some(t) = app.transcripts.get_mut(&id) else {
        buf.set_stringn(inner.x, inner.y, "loading…", inner.width as usize, c.dim());
        return;
    };
    crate::capacity_wait::sync(t, wait);
    if t.items.is_empty() && t.status != "running" {
        let project = project_label(&cwd);
        let headline = if project.is_empty() {
            "What should we build?".to_owned()
        } else {
            format!("What should we build in {project}?")
        };
        let top = inner.y + inner.height / 3;
        let w = headline.width().min(inner.width as usize);
        buf.set_stringn(
            inner.x + (inner.width as usize - w) as u16 / 2,
            top,
            &headline,
            w,
            Style::default().add_modifier(Modifier::BOLD),
        );
        let sub = "Type below and press Enter";
        let sw = sub.width().min(inner.width as usize);
        buf.set_stringn(
            inner.x + (inner.width as usize - sw) as u16 / 2,
            top + 2,
            sub,
            sw,
            c.dim(),
        );
        return;
    }
    let empty = std::collections::HashSet::new();
    let toggled = app.toggled.get(&id).unwrap_or(&empty);
    let changed_rows = app.transcript_cache.update(
        &id,
        t,
        inner.width as usize,
        app.show_thoughts,
        app.show_system,
        toggled,
        &c,
    );
    if let Some(changed) = changed_rows {
        // Per-frame work (cmux-view-rows frame_work): the rows the cache rebuilt, and their text
        // copied; a frame with no change to the transcript has none.
        #[cfg(test)]
        {
            let rebuilt = app.transcript_cache.rows.len().saturating_sub(changed);
            cmux_view_rows::frame_work::built(rebuilt);
            cmux_view_rows::frame_work::cloned(rebuilt);
        }
        app.rows_cache.truncate(changed);
        app.row_meta.truncate(changed);
        app.rows_cache
            .extend(app.transcript_cache.rows.iter().skip(changed).map(|r| r.text.clone()));
        app.row_meta
            .extend(app.transcript_cache.rows.iter().skip(changed).map(|r| (r.item, r.toggle)));
    }
    let rows = &app.transcript_cache.rows;
    let track = Rect { x: area.x + area.width - 1, y: inner.y, width: 1, height: inner.height };
    let mut link_runs: Vec<crate::links::LinkCell> = Vec::new();
    let anchor = app.transcript_anchor.clone();
    let vp = app.viewport.entry(id.clone()).or_default();
    vp.layout(rows.len(), inner.height as usize, track);
    if let Some((anchor_id, anchor_row, screen_row)) = anchor
        && anchor_id == id
    {
        // Preserve the clicked row even when a collapse leaves blank space
        // below the final item; moving the text under the pointer is worse.
        vp.offset = anchor_row.saturating_sub(screen_row);
        vp.follow = false;
    }
    if let Some(find) = app.find.as_mut() {
        if find.session != id {
            find.session = id.clone();
            find.matches.clear();
            find.stale = true;
        }
        if find.stale || changed_rows.is_some() {
            find.refresh(&app.rows_cache, vp.offset);
        }
        if std::mem::take(&mut find.reveal)
            && let Some(o) = find.reveal_offset(vp.offset, inner.height as usize, rows.len())
        {
            vp.offset = o;
            vp.follow = false;
        }
    }
    // A return lands at the "N new messages" line when the news runs past one screen.
    let new_row = app.new_line.as_ref().filter(|l| l.session == id).and_then(|l| {
        let meta: Vec<(usize, &str)> = rows.iter().map(|r| (r.item, r.text.as_str())).collect();
        crate::new_line::row(&meta, l.item)
    });
    if let (Some(r), Some(line)) = (new_row, app.new_line.as_mut())
        && !line.landed
    {
        line.landed = true;
        if let Some(o) = crate::new_line::landing(r, rows.len(), inner.height as usize) {
            vp.offset = o.min(vp.max_offset());
            vp.follow = false;
        }
    }
    vp.hover = hover.map(|(hx, hy)| vp.track_contains(hx, hy)).unwrap_or(false);
    let offset = vp.offset;
    let sel = app.selection.as_ref().filter(|s| s.session == id).cloned();
    app.transcript_hitboxes.clear();
    for (i, row) in rows.iter().enumerate().skip(offset).take(inner.height as usize) {
        #[cfg(test)]
        cmux_view_rows::frame_work::walked(1);
        let y = inner.y + (i - offset) as u16;
        let row_width = row.line.width().min(inner.width as usize) as u16;
        if row_width > 0 {
            app.transcript_hitboxes.push((Rect { x: inner.x, y, width: row_width, height: 1 }, i));
        }
        let p = Paragraph::new(
            super::cache::animated_line(t, row, &c).unwrap_or_else(|| row.line.clone()),
        );
        f_render(buf, p, Rect { x: inner.x, y, width: inner.width, height: 1 });
        // Codex app: a collapsible row lights up under the pointer.
        if row.toggle.is_some()
            && hover
                .map(|(hx, hy)| hy == y && hx >= inner.x && hx < inner.x.saturating_add(row_width))
                .unwrap_or(false)
        {
            let (lo, hi) = content_bounds(&row.text);
            for x in lo..hi.min(inner.width as usize).min(row_width as usize) {
                if let Some(cell) = buf.cell_mut((inner.x + x as u16, y)) {
                    cell.set_style(cell.style().bg(c.prompt_button_hover_bg));
                }
            }
        }
        // URLs and paths become OSC 8 hyperlinks the terminal can Cmd-click;
        // the backend attaches OSC 8 only to changed cells in the frame diff.
        for link in crate::links::find(&row.text) {
            let href = crate::links::href(&link.target, &cwd);
            let end = link.end.min(inner.width as usize);
            if link.start >= end {
                continue;
            }
            let mut text = String::new();
            let mut col = link.start;
            while col < end {
                let Some(cell) = buf.cell((inner.x + col as u16, y)) else {
                    break;
                };
                text.push_str(cell.symbol());
                col += cell.symbol().width().max(1);
            }
            link_runs.push(crate::links::LinkCell {
                x: inner.x + link.start as u16,
                y,
                text,
                href,
            });
        }
        if let Some(find) = &app.find {
            // Every match is marked; the current one is drawn reversed, as the GUI rings it.
            let from = find.matches.partition_point(|m| m.row < i);
            for (k, m) in find.matches.iter().enumerate().skip(from).take_while(|(_, m)| m.row == i)
            {
                let style = if k == find.current {
                    Style::default().add_modifier(Modifier::REVERSED | Modifier::BOLD)
                } else {
                    Style::default().bg(c.selection_bg).add_modifier(Modifier::UNDERLINED)
                };
                for x in m.start..m.end.min(inner.width as usize) {
                    if let Some(cell) = buf.cell_mut((inner.x + x as u16, y)) {
                        cell.set_style(cell.style().patch(style));
                    }
                }
            }
        }
        if let Some(s) = &sel
            && let Some((c0, c1)) = s.cols_on_row(i, &row.text)
        {
            for x in c0..c1.min(inner.width as usize) {
                if let Some(cell) = buf.cell_mut((inner.x + x as u16, y)) {
                    cell.set_style(cell.style().patch(c.selection()));
                }
            }
        }
    }
    // The "N new messages" line, over the blank row before the first new block (new_line.rs).
    if let (Some(r), Some(line)) = (new_row, app.new_line.as_ref())
        && r >= offset
        && r < offset + inner.height as usize
    {
        let w = (inner.width as usize).saturating_sub(2).min(COLUMN_WIDTH as usize);
        let text = crate::new_line::rule(&line.label(), w);
        let y = inner.y + (r - offset) as u16;
        buf.set_stringn(inner.x, y, &text, w, Style::default().fg(c.prompt_button_accent_fg));
    }
    app.link_cells.extend(link_runs);
    if vp.has_scrollbar() {
        draw_thumb(
            buf,
            track,
            vp.thumb(),
            c.scrollbar_thumb_fg,
            c.scrollbar_thumb_active_fg,
            vp.thumb_state(),
        );
    }
    if let Some(find) = &app.find {
        draw_find_bar(buf, inner, find, &c);
    }
    let below = vp.rows_below();
    if below > 0 {
        let tag = format!(" ↓ {below} more · End ");
        let w = tag.width() as u16;
        buf.set_stringn(
            inner.x + inner.width.saturating_sub(w),
            inner.y + inner.height.saturating_sub(1),
            &tag,
            w as usize,
            c.status_active(),
        );
    }
}

/// The find bar, top right over the transcript like the GUI's: "Find  query▏  3 of 12  esc".
fn draw_find_bar(buf: &mut Buffer, inner: Rect, find: &crate::chat_find::Find, c: &Chrome) {
    let count = find.count_label();
    let tail = if count.is_empty() { "  esc ".to_owned() } else { format!("  {count}  esc ") };
    let room = (inner.width as usize).saturating_sub(tail.width() + 8);
    let query: String = {
        // Keep the end of a long query, where the typing is.
        let mut w = 0;
        let mut kept: Vec<char> = Vec::new();
        for ch in find.query.chars().rev() {
            w += unicode_width::UnicodeWidthChar::width(ch).unwrap_or(0);
            if w > room {
                break;
            }
            kept.push(ch);
        }
        kept.into_iter().rev().collect()
    };
    let head = format!(" Find  {query}▏");
    let w = (head.width() + tail.width()).min(inner.width as usize) as u16;
    let x = inner.x + inner.width.saturating_sub(w);
    let style = c.status_active();
    buf.set_stringn(x, inner.y, &head, w as usize, style);
    let hw = head.width() as u16;
    if hw < w {
        buf.set_stringn(
            x + hw,
            inner.y,
            &tail,
            (w - hw) as usize,
            style.add_modifier(Modifier::DIM),
        );
    }
}

fn f_render(buf: &mut Buffer, p: Paragraph, area: Rect) {
    use ratatui::widgets::Widget;
    p.render(area, buf);
}
