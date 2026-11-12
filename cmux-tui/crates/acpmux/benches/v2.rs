//! The shared entry point for agent-service v2 god-vs-small gates.
//!
//! The rows are intentionally skipped until their owning PR supplies a measurement.  Keeping the
//! entry point live means the nightly report can name every promised row from PR 0 onward.

#[path = "v2/mod.rs"]
mod home;

fn main() {
    home::print_report();
}
