/// What an automation caller (the `cmux browser extension` CLI or a socket
/// client) may do with Chromium extensions.
///
/// Conservative by design until the trust-policy decision lands: anything
/// that gives an extension new reach into pages (installing, enabling,
/// invoking its action or commands, which grants `activeTab`) needs the
/// person to confirm in a cmux sheet; an agent can never answer that sheet.
/// Operations that only reduce or rearrange reach run directly. Packed
/// `.crx` files are refused: Chrome itself refuses off-store CRX installs on
/// macOS, and an unpacked folder or the Web Store covers every case.
/// Install prompts that Chromium raises (Web Store, `chrome.permissions`)
/// are always answered by the person in the app, never through automation.
public struct BrowserExtensionAutomationPolicy: Equatable, Sendable {
    /// The policy's decision for one operation.
    public enum Decision: Equatable, Sendable {
        /// Run it.
        case allow
        /// Run it only after the person accepts a cmux sheet in the target window.
        case requiresConsent
        /// Refuse it.
        case deny
    }

    /// Creates the policy.
    public init() {}

    /// The decision for `operation` when an automation caller asks.
    ///
    /// - Parameter operation: The requested operation.
    /// - Returns: Allow, consent first, or deny.
    public func decision(for operation: BrowserExtensionOperation) -> Decision {
        switch operation {
        case .list, .disable, .remove, .reload, .pin, .unpin, .move, .openWebStore:
            return .allow
        // An options page or chrome://extensions in an agent-driven tab could
        // change an extension's settings or access without the person.
        case .loadUnpacked, .enable, .run, .command, .options, .openManagement:
            return .requiresConsent
        case .installPacked:
            return .deny
        }
    }

    /// The decision for `operation` on a known extension.
    ///
    /// Reloading a crashed or running extension from the Web Store only
    /// restores what the person already allowed. Reloading one the person
    /// turned off would turn it back on, and reloading an unpacked extension
    /// re-reads its folder (whose manifest may have gained permissions since
    /// the person agreed), so both need consent like ``BrowserExtensionOperation/enable``.
    ///
    /// - Parameters:
    ///   - operation: The requested operation.
    ///   - target: The extension it acts on.
    /// - Returns: Allow, consent first, or deny.
    public func decision(for operation: BrowserExtensionOperation, target: BrowserExtensionInfo) -> Decision {
        if operation == .reload, (!target.isEnabled && !target.isTerminated) || target.location == .unpacked {
            return .requiresConsent
        }
        return decision(for: operation)
    }
}
