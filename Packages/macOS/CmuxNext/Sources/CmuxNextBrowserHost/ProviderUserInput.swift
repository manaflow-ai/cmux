public import AppKit

/// Which events of a person pause an agent's lease on a tab (`user.input`).
/// The app calls the provider only from its own event dispatch
/// (`NSApplication.sendEvent`), which driver input never passes: the WebKit
/// driver calls the web view directly and CDP input stays in Chromium.
public enum ProviderUserInput {
    /// One per press: key downs and mouse downs, not releases or drags.
    public static func pausesLease(_ event: NSEvent) -> Bool {
        false // RED: no event counts yet
    }
}
