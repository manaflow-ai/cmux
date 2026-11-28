use crate::{editor::Editor, links::split_line};

#[test]
fn numeric_only_link_is_a_filename_not_a_line_suffix() {
    assert_eq!(split_line("123"), ("123", None));
    assert_eq!(split_line("123:7"), ("123", Some(7)));
    assert_eq!(split_line("123:7:2"), ("123", Some(7)));
}

#[test]
fn link_suffix_preserves_unicode_paths_and_rejects_invalid_lines() {
    assert_eq!(split_line("路径.rs:12:5"), ("路径.rs", Some(12)));
    assert_eq!(split_line("路径.rs:abc"), ("路径.rs:abc", None));
    assert_eq!(split_line("路径.rs:4294967296"), ("路径.rs:4294967296", None));
    assert_eq!(split_line("https://example.com:123"), ("https://example.com:123", None));
    assert_eq!(split_line(""), ("", None));
}

#[test]
fn editor_rows_are_character_ranges_and_stale_ranges_are_empty() {
    let mut editor = Editor::default();
    editor.set_text("a界éz");
    assert_eq!(editor.row_text((1, 3)), "界é");
    assert_eq!(editor.row_text((3, 1)), "");
    assert_eq!(editor.row_text((0, usize::MAX)), "");
    let (old_rows, _) = editor.layout(2);
    editor.clear();
    for row in old_rows {
        assert_eq!(editor.row_text(row), "");
    }
}

#[test]
fn editor_click_beyond_layout_keeps_cursor_safe_for_next_insert() {
    let mut editor = Editor::default();
    editor.set_text("界é");
    editor.click(2, usize::MAX, usize::MAX);
    editor.insert('!');
    assert_eq!(editor.text(), "界é!");
    assert_eq!(editor.cursor(), 3);
}
