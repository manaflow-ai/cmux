public import CMUXMobileCore
public import CoreGraphics
import Foundation
public import Observation

/// Observable state for one streamed Mac browser panel.
@MainActor
@Observable
public final class BrowserStreamSurfaceState: Identifiable {
    /// A one-shot chrome command consumed by the representable.
    public enum ChromeCommand: Equatable, Sendable {
        /// Navigate backward.
        case back
        /// Navigate forward.
        case forward
        /// Reload the page.
        case reload
        /// Navigate to an address.
        case navigate(String)
    }

    /// Connection status displayed over the mirror.
    public enum ConnectionStatus: Equatable, Sendable {
        /// The RPC connection is ready.
        case connected
        /// The shell is attempting to recover the Mac connection.
        case reconnecting
        /// The Mac is unavailable.
        case disconnected
    }

    /// Browser subscription status.
    public enum StreamStatus: Equatable, Sendable {
        /// No stream is requested.
        case idle
        /// A start request is in flight or the first frame has not arrived.
        case starting
        /// Frames are actively arriving.
        case streaming
        /// The app lifecycle paused the stream.
        case paused
        /// The Mac panel closed.
        case closed
    }

    /// The Mac browser panel identifier.
    public let id: String
    /// The owning Mac workspace identifier.
    public private(set) var workspaceID: String
    /// The current page URL string.
    public private(set) var url: String?
    /// The current page title.
    public private(set) var title: String?
    /// Whether backward navigation is available.
    public private(set) var canGoBack: Bool
    /// Whether forward navigation is available.
    public private(set) var canGoForward: Bool
    /// Whether the page is loading.
    public private(set) var isLoading: Bool
    /// Estimated loading progress in `0...1`.
    public private(set) var progress: Double
    /// The streamed Mac page viewport size in points.
    public private(set) var pageSize: CGSize
    /// Whether the focused Mac page element accepts text.
    public private(set) var editableFocused: Bool
    /// Current Mac connection status.
    public var connectionStatus: ConnectionStatus
    /// Current browser subscription status.
    public var streamStatus: StreamStatus
    /// The latest frame actually installed into the display layer.
    public private(set) var latestFrame: BrowserStreamFrame?
    /// A pending chrome command consumed once by the representable.
    public private(set) var pendingCommand: ChromeCommand?
    /// Current unresolved native Mac browser dialog.
    public private(set) var pendingDialog: MobileBrowserDialogEvent?
    private var keyboardPolicy: BrowserStreamKeyboardPolicy
    private var newestDisplayedSequence: UInt64?

    /// Creates state from a discovered Mac browser panel.
    /// - Parameter descriptor: The panel's current wire descriptor.
    public init(descriptor: MobileBrowserPanelDescriptor) {
        id = descriptor.panelID
        workspaceID = descriptor.workspaceID
        url = descriptor.url
        title = descriptor.title
        canGoBack = descriptor.canGoBack
        canGoForward = descriptor.canGoForward
        isLoading = descriptor.isLoading
        progress = descriptor.isLoading ? 0 : 1
        pageSize = CGSize(width: descriptor.pageWidth, height: descriptor.pageHeight)
        editableFocused = false
        connectionStatus = .connected
        streamStatus = .idle
        latestFrame = nil
        pendingCommand = nil
        pendingDialog = descriptor.pendingDialog
        keyboardPolicy = BrowserStreamKeyboardPolicy()
        newestDisplayedSequence = nil
    }

    /// Updates discovery-owned descriptor fields.
    /// - Parameter descriptor: The latest panel descriptor.
    public func apply(_ descriptor: MobileBrowserPanelDescriptor) {
        let wasLoading = isLoading
        workspaceID = descriptor.workspaceID
        url = descriptor.url
        title = descriptor.title
        canGoBack = descriptor.canGoBack
        canGoForward = descriptor.canGoForward
        isLoading = descriptor.isLoading
        if !descriptor.isLoading {
            progress = 1
        } else if !wasLoading {
            progress = 0
        }
        pageSize = CGSize(width: descriptor.pageWidth, height: descriptor.pageHeight)
        if let pendingDialog = descriptor.pendingDialog {
            self.pendingDialog = pendingDialog
        }
    }

    /// Applies a browser state push from the Mac.
    /// - Parameter event: The decoded `browser.state` event.
    public func apply(_ event: MobileBrowserStateEvent) {
        guard event.panelID == id else { return }
        url = event.url
        title = event.title
        canGoBack = event.canGoBack
        canGoForward = event.canGoForward
        isLoading = event.isLoading
        progress = event.progress
        editableFocused = event.editableFocused
        keyboardPolicy.setEditableFocused(event.editableFocused)
    }

    /// Records a frame after it has been installed into the display layer.
    /// - Parameter frame: The displayed frame.
    public func didDisplay(_ frame: BrowserStreamFrame) {
        guard newestDisplayedSequence.map({ frame.sequence > $0 }) ?? true else { return }
        newestDisplayedSequence = frame.sequence
        latestFrame = frame
        pageSize = frame.pageSize
        streamStatus = .streaming
    }

    /// Queues a chrome command, replacing an older command that was not yet consumed.
    /// - Parameter command: The command to send to the Mac.
    public func request(_ command: ChromeCommand) {
        pendingCommand = command
    }

    /// Returns and clears the pending command so representable updates never replay it.
    /// - Returns: The pending command, or `nil` when no command is waiting.
    public func consumeCommand() -> ChromeCommand? {
        guard let pendingCommand else { return nil }
        self.pendingCommand = nil
        return pendingCommand
    }

    /// Whether the hidden input proxy should hold first responder.
    public var shouldFocusInput: Bool { keyboardPolicy.shouldFocusInput }

    /// Prepares sequence and status state for a new Mac stream subscription.
    public func prepareForStreamStart() {
        newestDisplayedSequence = nil
        streamStatus = .starting
    }

    /// Toggles the manual keyboard override for pages that do not report editable focus.
    public func toggleManualKeyboard() {
        keyboardPolicy.toggleManualRequest()
    }

    /// Installs the current native browser dialog for this panel.
    /// - Parameter dialog: Dialog pushed by the Mac.
    public func installDialog(_ dialog: MobileBrowserDialogEvent) {
        guard dialog.panelID == id else { return }
        pendingDialog = dialog
    }

    /// Clears a dialog only when the UUID still matches the current presentation.
    /// - Parameter dialogID: Dialog UUID resolved by either device.
    public func resolveDialog(dialogID: String) {
        guard pendingDialog?.dialogID == dialogID else { return }
        pendingDialog = nil
    }
}
