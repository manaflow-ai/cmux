//! The answer flow's card (tui/answering.rs), docked above the composer in
//! place of the permission card: the active item's header, prompt and
//! numbered options (checkboxes for a multi select), then the keys.

use super::*;
use crate::Answering;

/// A question or a command longer than this many lines stops there with an ellipsis, as the
/// GUI's card stops at 8 before its Show more (cmux#49455).
pub(super) const MAX_TEXT_LINES: usize = 8;

/// `text` wrapped at word breaks to `width` columns, at most `MAX_TEXT_LINES` lines; a word
/// wider than the line breaks inside it. The last line kept ends in "…" when more was cut.
pub(super) fn wrap_text(text: &str, width: usize) -> Vec<String> {
    let width = width.max(4);
    let mut lines: Vec<String> = Vec::new();
    for raw in text.trim().split('\n') {
        let mut line = String::new();
        for word in raw.split_whitespace() {
            let need = if line.is_empty() { word.width() } else { line.width() + 1 + word.width() };
            if need > width && !line.is_empty() {
                lines.push(std::mem::take(&mut line));
            }
            if !line.is_empty() {
                line.push(' ');
            }
            for ch in word.chars() {
                let cw = unicode_width::UnicodeWidthChar::width(ch).unwrap_or(0);
                if line.width() + cw > width {
                    lines.push(std::mem::take(&mut line));
                }
                line.push(ch);
            }
        }
        lines.push(line);
    }
    while lines.len() > 1 && lines.last().is_some_and(String::is_empty) {
        lines.pop();
    }
    if lines.len() > MAX_TEXT_LINES {
        lines.truncate(MAX_TEXT_LINES);
        if let Some(last) = lines.last_mut() {
            while last.width() + 1 > width {
                last.pop();
            }
            last.push('…');
        }
    }
    lines
}

/// The inner width the card gives its text, for a card `card_w` columns wide.
pub(super) fn text_width(card_w: u16) -> usize {
    card_w.saturating_sub(4) as usize
}

/// Rows the card needs at `card_w` columns: borders, head, the whole prompt, one per option, keys.
pub(super) fn card_height(flow: &Answering, card_w: u16) -> u16 {
    let item = flow.active();
    let options = item.and_then(|i| i["options"].as_array()).map_or(0, Vec::len);
    let prompt = item.and_then(|i| i["prompt"].as_str()).unwrap_or("");
    let prompt_rows = wrap_text(prompt, text_width(card_w)).len().max(1);
    4 + prompt_rows as u16 + options.min(9) as u16
}

pub(super) fn draw_question_card(
    f: &mut ratatui::Frame,
    area: Rect,
    flow: &Answering,
    app: &mut App,
) {
    let c = app.chrome;
    let hover = app.hover;
    let buf = f.buffer_mut();
    app.perm_rows.clear();
    let Some(item) = flow.active() else { return };
    if area.height < 4 || area.width < 12 {
        return;
    }
    fill(buf, area, Style::default());
    super::composer::rounded_border(buf, area, Style::default().fg(c.attention_fg));
    let inner_w = area.width.saturating_sub(4) as usize;
    let x = area.x + 2;
    let total = acpmux::question_answer::items(&flow.question).len();
    let agent = flow.question.get("agent").and_then(|agent| agent.as_str()).unwrap_or("The agent");
    let header = item["header"].as_str().unwrap_or("");
    let mut head = format!("{agent} asks");
    if total > 1 {
        head.push_str(&format!("  ·  {}/{total}", flow.item + 1));
    }
    if !header.is_empty() {
        head.push_str(&format!("  ·  {header}"));
    }
    let bold = Style::default().fg(c.attention_fg).add_modifier(Modifier::BOLD);
    buf.set_stringn(x, area.y + 1, truncate(&head, inner_w), inner_w, bold);
    // The whole question, wrapped at word breaks (cmux#49455), never cut to one line.
    let prompt = item["prompt"].as_str().unwrap_or("");
    let last = area.y + area.height.saturating_sub(2);
    let prompt_lines = wrap_text(prompt, inner_w);
    let mut y = area.y + 2;
    for line in &prompt_lines {
        if y >= last {
            break;
        }
        buf.set_stringn(x, y, line, inner_w, Style::default());
        y += 1;
    }
    let first_option = area.y + 2 + prompt_lines.len().max(1) as u16;
    let multi = item["multiSelect"].as_bool().unwrap_or(false);
    let options = item["options"].as_array().map(Vec::as_slice).unwrap_or(&[]);
    for (i, option) in options.iter().enumerate().take(9) {
        let y = first_option + i as u16;
        if y >= last {
            break;
        }
        let mark = if i == flow.highlight { "›" } else { " " };
        let check = match (multi, flow.picked.contains(&i)) {
            (false, _) => "",
            (true, true) => "[x] ",
            (true, false) => "[ ] ",
        };
        let label = option["label"].as_str().unwrap_or("");
        let detail = option["detail"].as_str().unwrap_or("");
        let detail = if detail.is_empty() { String::new() } else { format!("  {detail}") };
        let line = format!("{mark} {}. {check}{label}", i + 1);
        let r = Rect { x, y, width: area.width.saturating_sub(4), height: 1 };
        let hovered =
            hover.map(|(hx, hy)| hy == r.y && hx >= r.x && hx < r.x + r.width).unwrap_or(false);
        let style = if hovered {
            Style::default().bg(c.status_active_bg).fg(c.status_active_fg)
        } else if i == flow.highlight {
            Style::default().fg(c.prompt_button_accent_fg)
        } else {
            Style::default()
        };
        buf.set_stringn(x, y, &line, inner_w, style);
        let used = line.width();
        if used + 2 < inner_w {
            buf.set_stringn(x + used as u16, y, &detail, inner_w - used, c.dim());
        }
        app.perm_rows.push((r, ButtonAction::PermissionOption(i)));
    }
    let other = item["allowsOther"].as_bool().unwrap_or(false);
    let keys = match (multi, other) {
        _ if item["input"] == "number" => "type a number · Enter confirms · Esc leaves",
        _ if options.is_empty() => "type your answer · Enter confirms · Esc leaves",
        (true, true) => "digits/Space toggle · type for Other · Enter confirms · Esc leaves",
        (true, false) => "digits/Space toggle · Enter confirms · Esc leaves",
        (false, true) => "digit picks · type for Other · Enter confirms · Esc leaves",
        (false, false) => "digit picks · Enter confirms · Esc leaves",
    };
    buf.set_stringn(x, last, truncate(keys, inner_w), inner_w, c.dim());
    app.dialog_rect = area;
}

#[cfg(test)]
#[path = "question_tests.rs"]
mod tests;
