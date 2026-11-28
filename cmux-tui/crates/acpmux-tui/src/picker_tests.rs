use super::*;

fn row(value: &str, header: bool) -> PickRow {
    PickRow {
        value: value.into(),
        label: value.into(),
        header,
        group: String::new(),
        note: String::new(),
    }
}

#[test]
fn stale_visible_indices_are_skipped_without_panicking() {
    let mut picker = Picker::new(
        "test",
        vec![row("group", true), row("chosen", false)],
        None,
        PickTarget::Action,
        "",
    );
    picker.visible = vec![usize::MAX, 0, 1];
    picker.cursor = 0;
    assert!(picker.selected().is_none());
    picker.snap_cursor(1);
    assert_eq!(picker.selected().map(|r| r.value.as_str()), Some("chosen"));
    picker.cursor = 0;
    picker.move_by(1);
    assert_eq!(picker.selected().map(|r| r.value.as_str()), Some("chosen"));
    picker.rows.clear();
    picker.snap_cursor(-1);
    picker.move_by(1);
    assert!(picker.selected().is_none());
}

#[test]
fn filtering_retains_only_headers_with_matching_children() {
    let mut picker = Picker::new(
        "test",
        vec![row("first", true), row("alpha", false), row("second", true), row("beta", false)],
        None,
        PickTarget::Action,
        "",
    );
    picker.filter.set_text("beta");
    picker.refilter();
    assert_eq!(picker.visible, vec![2, 3]);
    assert_eq!(picker.selected().map(|r| r.value.as_str()), Some("beta"));
}
