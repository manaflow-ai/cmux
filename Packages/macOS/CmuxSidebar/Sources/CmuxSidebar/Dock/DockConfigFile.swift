import Foundation

/// The on-disk shape of a Dock config file: a list of ``DockControlDefinition``.
///
/// This is the `Codable` root decoded from `.cmux/dock.json` (project scope) or
/// `~/.config/cmux/dock.json` (global scope), and the value re-encoded both to
/// write the starter template and to fingerprint the config for trust prompts.
public struct DockConfigFile: Codable {
    /// The Dock controls declared in the file, in declaration order.
    public let controls: [DockControlDefinition]

    /// Creates a Dock config file wrapping the given controls.
    public init(controls: [DockControlDefinition]) {
        self.controls = controls
    }
}
