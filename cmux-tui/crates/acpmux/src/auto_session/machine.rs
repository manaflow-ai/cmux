//! The Cloud machine's side. Owned by slice C (the Cloud machine daemon).
//!
//! The machine's transport: `cmux_auto_session::AutoCloud` through the machine's Cloud agent
//! (cmux-host `cloud/auto_session.rs`), which holds the VM install's bearer. Also the assignment
//! reader: at start, at resume and while the daemon runs (a held request of at most 25 s) it
//! reads this machine's assignments and hands each to the holder loop ([`super::spawn_holder`])
//! as an `Assigned` event; the loop imports and then acks.
