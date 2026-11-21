//! Continuations consume their actual escaped wire size, even for hidden rows.
use super::*;
use crate::wire::{
    FolderPageResult, FolderPosition, FolderWindow, ListView, Page, PageSide, Position,
};

#[test]
fn escaped_folder_continuations_fit_and_page_in_both_directions() {
    let (hub, mut writer) = Hub::new(SummaryIndex::new());
    let mut expected = Vec::new();
    for n in 0..4 {
        let folder = format!("{}{}", "\u{0001}".repeat(1023), n);
        let mut row = Summary::new(format!("chat-{n}"));
        row.folder = Some(folder.clone());
        row.last_activity = 10 - n;
        writer.apply(row).unwrap();
        expected.push(folder);
    }
    let sid = "\u{0002}".repeat(256);
    let mut sub = Sub::new(sid.clone(), "list");
    sub.view = Some(ListView::Folders);
    let window: FolderWindow = hub.list_window(&sub).unwrap().decode_json().unwrap();
    assert_eq!(window.rows.len(), 4);
    let first = window.rows.first().unwrap();
    let key = FolderPosition {
        at: first.at,
        origin: first.origin.to_string(),
        folder: first.folder.to_string(),
    };
    // One returned row, two whole continuations, and the shared envelope reserve.
    let budget = 8192
        + serde_json::to_vec(&sid).unwrap().len()
        + 2 * serde_json::to_vec(&key).unwrap().len()
        + first.encoded_len()
        + 1;
    let mut page = Page::new(sid, "list", PageSide::After, 0);
    page.view = Some(ListView::Folders);
    page.after = None;
    page.max_bytes = budget as u32;
    let mut seen = Vec::new();
    let last = loop {
        let frame = hub.page(&page).unwrap();
        assert!(frame.encoded_len() <= budget);
        let result: FolderPageResult = frame.decode_json().unwrap();
        assert_eq!(result.rows.len(), 1);
        let row = result.rows.first().unwrap();
        assert_eq!(result.before_key.as_ref().unwrap().folder, row.folder.as_ref());
        assert_eq!(result.after_key.as_ref().unwrap().folder, row.folder.as_ref());
        seen.push(row.folder.to_string());
        if !result.has_after {
            break result.before_key.unwrap();
        }
        page.after = result.after_key.map(Position::Folder);
    };
    assert_eq!(seen, expected);
    page.after = None;
    page.before = Some(Position::Folder(last));
    let frame = hub.page(&page).unwrap();
    assert!(frame.encoded_len() <= budget);
    let result: FolderPageResult = frame.decode_json().unwrap();
    assert_eq!(result.rows.len(), 1);
    assert_eq!(result.rows.first().unwrap().folder.as_ref(), expected.get(2).unwrap());
    assert!(result.has_before);
}
