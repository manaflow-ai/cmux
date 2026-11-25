//! Markdown → transcript rows. pulldown-cmark parses; this module turns
//! the event stream into styled, width-wrapped `Row`s: headings, emphasis,
//! inline code, links, nested bullet and numbered lists, block quotes,
//! rules, simple tables, and fenced code blocks highlighted by syntect
//! on a shaded background. Every row keeps its plain text for copying.

use super::render::Row;
use super::theme::Chrome;
use pulldown_cmark::{CodeBlockKind, Event, Options, Parser, Tag, TagEnd};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use std::sync::OnceLock;
use syntect::highlighting::{Theme, ThemeSet};
use syntect::parsing::SyntaxSet;
use unicode_width::{UnicodeWidthChar, UnicodeWidthStr};

fn syntaxes() -> &'static SyntaxSet {
    static S: OnceLock<SyntaxSet> = OnceLock::new();
    S.get_or_init(SyntaxSet::load_defaults_newlines)
}

fn theme(name: &str) -> &'static Theme {
    static T: OnceLock<ThemeSet> = OnceLock::new();
    let set = T.get_or_init(ThemeSet::load_defaults);
    set.themes.get(name).or_else(|| set.themes.values().next()).expect("syntect ships themes")
}

/// A styled inline fragment before wrapping.
type Frag = (String, Style);

/// Greedy word wrap over styled fragments. The first row gets `first`,
/// later rows `cont`, both drawn in `gutter_style`.
pub fn wrap_frags(
    frags: &[Frag],
    width: usize,
    first: &str,
    cont: &str,
    gutter_style: Style,
    item: usize,
    out: &mut Vec<Row>,
) {
    let width = width.max(4);
    // Break fragments into words that keep their style; spaces are words too.
    let mut words: Vec<Frag> = Vec::new();
    for (text, style) in frags {
        let mut cur = String::new();
        for ch in text.chars() {
            if ch == ' ' {
                if !cur.is_empty() {
                    words.push((std::mem::take(&mut cur), *style));
                }
                words.push((" ".into(), *style));
            } else {
                cur.push(ch);
            }
        }
        if !cur.is_empty() {
            words.push((cur, *style));
        }
    }
    let mut line: Vec<Frag> = Vec::new();
    let mut line_w = 0usize;
    let mut first_row = true;
    let flush = |line: &mut Vec<Frag>, first_row: &mut bool, out: &mut Vec<Row>| {
        // Trim a trailing space left by the break.
        while line.last().map(|(t, _)| t == " ").unwrap_or(false) {
            line.pop();
        }
        let prefix = if *first_row { first } else { cont };
        let mut spans = vec![Span::styled(prefix.to_owned(), gutter_style)];
        let mut text = prefix.to_owned();
        for (t, s) in line.drain(..) {
            text.push_str(&t);
            spans.push(Span::styled(t, s));
        }
        out.push(Row { line: Line::from(spans), text, item, toggle: None });
        *first_row = false;
    };
    for (word, style) in words {
        let ww = word.width();
        if word == " " {
            if line_w == 0 {
                continue; // no leading spaces after a break
            }
            if line_w + 1 > width {
                flush(&mut line, &mut first_row, out);
                line_w = 0;
                continue;
            }
            line.push((word, style));
            line_w += 1;
            continue;
        }
        if line_w + ww > width && line_w > 0 {
            flush(&mut line, &mut first_row, out);
            line_w = 0;
        }
        if ww > width {
            // Hard-split a word longer than the row.
            let mut chunk = String::new();
            let mut cw = 0;
            for ch in word.chars() {
                let w = ch.width().unwrap_or(0);
                if cw + w > width {
                    line.push((std::mem::take(&mut chunk), style));
                    flush(&mut line, &mut first_row, out);
                    cw = 0;
                }
                chunk.push(ch);
                cw += w;
            }
            line.push((chunk, style));
            line_w = cw;
            continue;
        }
        line.push((word, style));
        line_w += ww;
    }
    if !line.is_empty() || first_row {
        flush(&mut line, &mut first_row, out);
    }
}

/// A fenced code block: one row per line on the code background, cut
/// (not wrapped) at the width, highlighted when the language is known.
fn code_rows(
    code: &str,
    lang: &str,
    width: usize,
    indent: &str,
    c: &Chrome,
    item: usize,
    out: &mut Vec<Row>,
) {
    let width = width.max(4);
    let bg = Style::default().bg(c.code_bg);
    let ss = syntaxes();
    let syntax = if lang.is_empty() {
        None
    } else {
        ss.find_syntax_by_token(lang.split(|ch: char| !ch.is_alphanumeric()).next().unwrap_or(lang))
    };
    let mut hl = syntax.map(|s| syntect::easy::HighlightLines::new(s, theme(c.code_theme)));
    if !lang.is_empty() {
        let label = format!("{indent} {lang}");
        let pad = width.saturating_sub(label.width());
        out.push(Row {
            line: Line::from(vec![
                Span::styled(label.clone(), bg.fg(c.status_dim_fg)),
                Span::styled(" ".repeat(pad), bg),
            ]),
            text: label,
            item,
            toggle: None,
        });
    }
    for raw in code.lines() {
        let line_nl = format!("{raw}\n");
        let mut spans: Vec<Span<'static>> = vec![Span::styled(format!("{indent} "), bg)];
        let mut used = 1usize;
        let pieces: Vec<(Style, String)> = match hl.as_mut() {
            Some(h) => h
                .highlight_line(&line_nl, ss)
                .map(|v| {
                    v.into_iter()
                        .map(|(st, s)| {
                            (
                                bg.fg(Color::Rgb(
                                    st.foreground.r,
                                    st.foreground.g,
                                    st.foreground.b,
                                )),
                                s.trim_end_matches('\n').to_owned(),
                            )
                        })
                        .collect()
                })
                .unwrap_or_else(|_| vec![(bg.fg(c.code_fg), raw.to_owned())]),
            None => vec![(bg.fg(c.code_fg), raw.to_owned())],
        };
        'outer: for (st, s) in pieces {
            let mut piece = String::new();
            for ch in s.chars() {
                let w = ch.width().unwrap_or(0);
                if used + w > width.saturating_sub(1) {
                    piece.push('…');
                    spans.push(Span::styled(piece, st));
                    used = width;
                    break 'outer;
                }
                piece.push(ch);
                used += w;
            }
            spans.push(Span::styled(piece, st));
        }
        // Pad to the full width so the block reads as one shaded panel.
        if used < width {
            spans.push(Span::styled(" ".repeat(width - used), bg));
        }
        out.push(Row {
            line: Line::from(spans),
            text: format!("{indent} {raw}"),
            item,
            toggle: None,
        });
    }
}

/// Render markdown into rows. `indent` is the left gutter every row gets;
/// `base` styles plain text. Spacing follows Codex's renderer: one blank
/// row between blocks (paragraphs, headings, lists, code, quotes, rules),
/// list items kept together, `- ` bullets indented four columns per level,
/// `N. ` for ordered lists. Styles: h1 bold underlined, h2 bold, h3 bold
/// italic, h4+ italic, code cyan, links cyan underlined, quotes green.
pub fn render(
    text: &str,
    width: usize,
    indent: &str,
    base: Style,
    c: &Chrome,
    item: usize,
    out: &mut Vec<Row>,
) {
    let opts = Options::ENABLE_STRIKETHROUGH | Options::ENABLE_TABLES | Options::ENABLE_TASKLISTS;
    let parser = Parser::new_ext(text, opts);
    let gutter = Style::default();
    let mut frags: Vec<Frag> = Vec::new();
    let mut styles: Vec<Style> = vec![base];
    // Each list level: ordered counter.
    let mut lists: Vec<Option<u64>> = Vec::new();
    let mut item_first_prefix: Option<String> = None;
    let mut quote = 0usize;
    let mut code: Option<(String, String)> = None; // (lang, text)
    let mut in_table = false;
    let mut table_row: Vec<String> = Vec::new();
    let mut cell = String::new();
    let mut link_url: Option<String> = None;
    let mut link_text = String::new();
    // A block just ended: the next block gets a blank row first.
    let mut needs_blank = false;
    let start_len = out.len();

    let cur = |styles: &Vec<Style>| *styles.last().unwrap_or(&base);
    let blank = |out: &mut Vec<Row>, needs_blank: &mut bool| {
        if *needs_blank && out.len() > start_len {
            out.push(Row { line: Line::from(""), text: String::new(), item, toggle: None });
        }
        *needs_blank = false;
    };
    let list_pad = |lists: &Vec<Option<u64>>| -> String {
        // Codex: marker width = depth * 4 - 3, right-aligned before "- ".
        let depth = lists.len().max(1);
        " ".repeat(depth * 4 - 4)
    };
    let flush_para = |frags: &mut Vec<Frag>,
                      item_first_prefix: &mut Option<String>,
                      lists: &Vec<Option<u64>>,
                      quote: usize,
                      out: &mut Vec<Row>| {
        if frags.is_empty() {
            return;
        }
        let q = if quote > 0 { "│ ".repeat(quote) } else { String::new() };
        let pad = if lists.is_empty() { String::new() } else { list_pad(lists) };
        let marker = item_first_prefix.take().unwrap_or_default();
        let first = format!("{indent}{q}{pad}{marker}");
        let cont_pad = " ".repeat(first.width().saturating_sub(indent.width() + q.width()));
        let cont = format!("{indent}{q}{cont_pad}");
        let inner_w = width.saturating_sub(first.width());
        wrap_frags(frags, inner_w.max(8), &first, &cont, gutter.fg(c.status_dim_fg), item, out);
        frags.clear();
    };

    for ev in parser {
        match ev {
            Event::Start(tag) => match tag {
                Tag::Paragraph if (lists.is_empty() || item_first_prefix.is_none()) => {
                    blank(out, &mut needs_blank);
                }
                Tag::Heading { level, .. } => {
                    blank(out, &mut needs_blank);
                    let st = match level as u8 {
                        1 => base.add_modifier(Modifier::BOLD | Modifier::UNDERLINED),
                        2 => base.add_modifier(Modifier::BOLD),
                        3 => base.add_modifier(Modifier::BOLD | Modifier::ITALIC),
                        _ => base.add_modifier(Modifier::ITALIC),
                    };
                    styles.push(st);
                }
                Tag::BlockQuote(_) => {
                    blank(out, &mut needs_blank);
                    quote += 1;
                    styles.push(cur(&styles).fg(Color::Green));
                }
                Tag::CodeBlock(kind) => {
                    flush_para(&mut frags, &mut item_first_prefix, &lists, quote, out);
                    blank(out, &mut needs_blank);
                    let lang = match kind {
                        CodeBlockKind::Fenced(l) => l.to_string(),
                        CodeBlockKind::Indented => String::new(),
                    };
                    code = Some((lang, String::new()));
                }
                Tag::List(start) => {
                    flush_para(&mut frags, &mut item_first_prefix, &lists, quote, out);
                    if lists.is_empty() {
                        blank(out, &mut needs_blank);
                    }
                    lists.push(start);
                }
                Tag::Item => {
                    flush_para(&mut frags, &mut item_first_prefix, &lists, quote, out);
                    let marker = match lists.last_mut() {
                        Some(Some(n)) => {
                            let m = format!("{n}. ");
                            *n += 1;
                            m
                        }
                        _ => "- ".to_owned(),
                    };
                    item_first_prefix = Some(marker);
                }
                Tag::Emphasis => styles.push(cur(&styles).add_modifier(Modifier::ITALIC)),
                Tag::Strong => styles.push(cur(&styles).add_modifier(Modifier::BOLD)),
                Tag::Strikethrough => styles.push(cur(&styles).add_modifier(Modifier::CROSSED_OUT)),
                Tag::Link { dest_url, .. } => {
                    styles.push(cur(&styles).fg(c.link_fg).add_modifier(Modifier::UNDERLINED));
                    link_url = Some(dest_url.to_string());
                    link_text.clear();
                }
                Tag::Table(_) => {
                    flush_para(&mut frags, &mut item_first_prefix, &lists, quote, out);
                    blank(out, &mut needs_blank);
                    in_table = true;
                }
                Tag::TableHead | Tag::TableRow => table_row.clear(),
                Tag::TableCell => cell.clear(),
                _ => {}
            },
            Event::End(tag) => match tag {
                TagEnd::Paragraph => {
                    flush_para(&mut frags, &mut item_first_prefix, &lists, quote, out);
                    // Inside a list, items stay together; after the list a blank follows.
                    needs_blank = lists.is_empty();
                }
                TagEnd::Heading(_) => {
                    flush_para(&mut frags, &mut item_first_prefix, &lists, quote, out);
                    styles.pop();
                    needs_blank = true;
                }
                TagEnd::BlockQuote(_) => {
                    flush_para(&mut frags, &mut item_first_prefix, &lists, quote, out);
                    quote = quote.saturating_sub(1);
                    styles.pop();
                    needs_blank = true;
                }
                TagEnd::CodeBlock => {
                    if let Some((lang, text)) = code.take() {
                        code_rows(&text, &lang, width, indent, c, item, out);
                    }
                    needs_blank = true;
                }
                TagEnd::List(_) => {
                    flush_para(&mut frags, &mut item_first_prefix, &lists, quote, out);
                    lists.pop();
                    needs_blank = lists.is_empty();
                }
                TagEnd::Item => flush_para(&mut frags, &mut item_first_prefix, &lists, quote, out),
                TagEnd::Link => {
                    styles.pop();
                    // Keep the URL visible after the text unless the text is the URL.
                    if let Some(url) = link_url.take()
                        && link_text.trim() != url.trim()
                        && !url.is_empty()
                    {
                        frags.push((format!(" ({url})"), base.fg(c.status_dim_fg)));
                    }
                }
                TagEnd::Emphasis | TagEnd::Strong | TagEnd::Strikethrough => {
                    styles.pop();
                }
                TagEnd::TableCell => table_row.push(std::mem::take(&mut cell)),
                TagEnd::TableHead | TagEnd::TableRow => {
                    let text = format!("{indent}{}", table_row.join("  │  "));
                    let style = if matches!(tag, TagEnd::TableHead) {
                        base.add_modifier(Modifier::BOLD)
                    } else {
                        base
                    };
                    out.push(Row {
                        line: Line::from(Span::styled(text.clone(), style)),
                        text,
                        item,
                        toggle: None,
                    });
                }
                TagEnd::Table => {
                    in_table = false;
                    needs_blank = true;
                }
                _ => {}
            },
            Event::Text(t) => {
                if let Some((_, buf)) = code.as_mut() {
                    buf.push_str(&t);
                } else if in_table {
                    cell.push_str(&t);
                } else {
                    if link_url.is_some() {
                        link_text.push_str(&t);
                    }
                    frags.push((t.to_string(), cur(&styles)));
                }
            }
            Event::Code(t) => {
                if in_table {
                    cell.push_str(&t);
                } else {
                    frags.push((format!(" {t} "), cur(&styles).bg(c.code_bg).fg(c.code_fg)));
                }
            }
            Event::SoftBreak => {
                if in_table {
                    cell.push(' ');
                } else {
                    frags.push((" ".into(), cur(&styles)));
                }
            }
            Event::HardBreak => {
                flush_para(&mut frags, &mut item_first_prefix, &lists, quote, out);
            }
            Event::Rule => {
                flush_para(&mut frags, &mut item_first_prefix, &lists, quote, out);
                blank(out, &mut needs_blank);
                let text = format!("{indent}———");
                out.push(Row {
                    line: Line::from(Span::styled(text.clone(), base.fg(c.status_dim_fg))),
                    text,
                    item,
                    toggle: None,
                });
                needs_blank = true;
            }
            Event::TaskListMarker(done) => {
                frags.push((if done { "[x] " } else { "[ ] " }.into(), cur(&styles)));
            }
            _ => {}
        }
    }
    flush_para(&mut frags, &mut item_first_prefix, &lists, quote, out);
    if let Some((lang, text)) = code.take() {
        code_rows(&text, &lang, width, indent, c, item, out);
    }
}
