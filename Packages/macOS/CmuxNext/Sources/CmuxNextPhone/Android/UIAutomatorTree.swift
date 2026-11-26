import Foundation

/// Parses `uiautomator dump` XML into a ``PhoneElement`` tree, frames in dp
/// (`cmux-phone-core`'s op `uiautomator_tree`).
struct UIAutomatorTree {
    /// Pixels per dp of the dumped screen.
    let pixelsPerPoint: Double

    func parse(_ output: Data) throws -> PhoneElement {
        try PhoneRules.decode(PhoneElement.self, "root", "uiautomator_tree",
                              ["output": PhoneRules.text(output), "pixels_per_point": pixelsPerPoint],
                              what: "the UI Automator dump")
    }
}
