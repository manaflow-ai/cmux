//! An idle memory editor costs no wakeup (perf-lead.md row 9, 2026-11-21): the
//! `memory-rebuild` worker woke every 500 ms forever with nothing queued, 2 of
//! the Chief host's 3.49 wakeups a second at idle. It now sleeps until a change
//! queues a rebuild or the editor goes.

use std::sync::Arc;
use std::time::Duration;

use optchat_chief::inspect::edit::Editor;
use optchat_host::{
    CompactModel, CompactRequest, Config, Followup, ModelError, OptChat, Reply, SystemClock,
};

struct Echo;

impl CompactModel for Echo {
    fn call(&self, _: &CompactRequest, _: &[Followup]) -> Result<Reply, ModelError> {
        Ok(Reply::text("summary".to_owned()))
    }
}

fn editor(dir: &std::path::Path) -> Arc<Editor> {
    let config = Config {
        reporter: Arc::new(|_| {}),
        ..Config::default()
    };
    let chat = Arc::new(
        OptChat::open_with(
            dir.join("chat"),
            config,
            Arc::new(Echo),
            Arc::new(SystemClock),
        )
        .unwrap(),
    );
    Editor::open(chat, dir)
}

#[test]
fn an_idle_editor_never_wakes_its_worker() {
    let dir = tempfile::tempdir().unwrap();
    let editor = editor(dir.path());
    assert!(editor.wait_rebuilt(Duration::from_secs(10)));
    std::thread::sleep(Duration::from_millis(1600));
    assert_eq!(
        editor.idle_wakes(),
        0,
        "the worker woke with nothing to build"
    );
}

#[test]
fn a_dropped_editor_is_gone_at_once() {
    let dir = tempfile::tempdir().unwrap();
    let editor = editor(dir.path());
    assert!(editor.wait_rebuilt(Duration::from_secs(10)));
    std::thread::sleep(Duration::from_millis(100));
    let weak = Arc::downgrade(&editor);
    drop(editor);
    assert!(
        weak.upgrade().is_none(),
        "the idle worker kept the editor alive"
    );
}
