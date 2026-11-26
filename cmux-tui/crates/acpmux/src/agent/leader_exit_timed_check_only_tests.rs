thread_local! {
    static ON: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
}
pub(crate) fn set(on: bool) {
    ON.with(|o| o.set(on));
}
pub(super) fn on() -> bool {
    ON.with(std::cell::Cell::get)
}
