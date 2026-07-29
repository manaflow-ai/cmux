# cmux Ratatui sidebar

`cmux-sidebar` is an optional companion to the base Rust SDK. It attaches to a
typed sidebar view, receives updates on a worker thread, retains at most the
configured number of pending updates, reconciles typed render snapshots and
patches, renders resolved colors and attributes as a Ratatui widget, and
forwards Crossterm keyboard, mouse, paste, focus, and resize input.

```rust
use cmux_sidebar::{SidebarConfig, SidebarRuntime};

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
sidebar.shutdown()?;
# Ok(())
# }
```

Queue overflow cancels the attachment and puts a recovery message in the
render model. `shutdown` cancels and joins the worker. Dropping the runtime
cancels only the attachment lease and never deletes or disables the view.

Run the example:

```bash
cd cmux-tui
cargo run -p cmux-sidebar --example sidebar
```
