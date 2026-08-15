# cmux Ratatui sidebar

`cmux-sidebar` is an optional companion to the base Rust SDK. It attaches to a
typed sidebar view, receives updates on a worker thread, retains at most the
configured number of pending updates, reconciles typed render snapshots and
patches, renders resolved colors and attributes as a Ratatui widget, and
forwards Crossterm keyboard, mouse, paste, focus, and resize input.

```rust
use cmux_sidebar::{SidebarConfig, SidebarRuntime, SidebarRuntimeState};

# fn example(view: cmux::SidebarView) -> cmux::Result<()> {
let mut sidebar = SidebarRuntime::start(
    view,
    SidebarConfig {
        queue_capacity: 64,
        initial_columns: Some(32),
        initial_rows: Some(24),
        fallback_title: "project".to_string(),
    },
)?;
sidebar.poll_updates();
# let _widget = sidebar.widget();
if !matches!(sidebar.state(), SidebarRuntimeState::Attached) {
    sidebar.reattach()?;
}
sidebar.shutdown()?;
# Ok(())
# }
```

`SidebarRuntimeState::Ended` preserves the complete typed stream end, including
the cursor, recovery directive, and protocol error. Queue overflow has its own
typed state. `reattach` opens a fresh lease while retaining the last frame.
`shutdown` cancels and joins the worker. Dropping the runtime cancels only the
attachment lease and never deletes or disables the view.

Applications that own their stream and recovery policy can reuse the public
pieces independently. The reducer preserves unknown event counts, kinds, and
raw documents so newer server events remain observable:

```rust
# use cmux::{SidebarViewItem, StreamEnd};
# use cmux_sidebar::{SidebarModel, SidebarWidget};
# use ratatui::text::Line;
# fn example(item: SidebarViewItem, end: StreamEnd) {
let mut model = SidebarModel::new("project");
model.apply_item(item);
let widget = SidebarWidget::new(&model)
    .without_block()
    .footer(Line::from(format!("ended: {:?}", end.reason)));
# let _ = widget;
# }
```

Run the example:

```bash
cd cmux-tui
cargo run -p cmux-sidebar --example sidebar
```
