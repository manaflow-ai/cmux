#if os(iOS)
public import CmuxMobileCloud
public import Foundation
public import Observation

/// Owns one terminal's attachment: it holds the live attachment, applies link
/// output to an embedding surface through ``CloudTerminalOutputReducer``, and
/// forwards typing and grid reports.
///
/// The surface is set by the representable when its UIKit view mounts. Output
/// events arrive on library threads and are hopped to the main actor here.
@MainActor
@Observable
public final class CloudTerminalScreenModel {
    /// The attachment's lifecycle for the screen's overlay.
    public enum Phase: Sendable, Equatable {
        case attaching
        case attached
        case failed(CloudSessionFailure)
        case exited
    }

    /// The current phase.
    public private(set) var phase: Phase = .attaching

    /// What the surface must be able to do for this model to drive it.
    @MainActor
    public protocol Surface: AnyObject {
        /// Feed terminal bytes to the emulator.
        func writeOutput(_ data: Data)
        /// Pin the emulator grid.
        func applyGrid(cols: Int, rows: Int)
    }

    private weak var surface: (any Surface)?
    private var reducer = CloudTerminalOutputReducer()
    private var attachment: CloudTerminalAttachment?
    private var pending: [CloudTerminalOutputReducer.Action] = []

    /// Creates a model.
    public init() {}

    /// The representable calls this when its surface view is ready, replaying
    /// any actions that arrived before the surface existed.
    public func setSurface(_ surface: any Surface) {
        self.surface = surface
        let queued = pending
        pending.removeAll()
        for action in queued { apply(action) }
    }

    /// Attach (or re-attach) to `terminalID` over `connection`.
    public func attach(connection: CloudMachineConnection, terminalID: String) async {
        phase = .attaching
        reducer = CloudTerminalOutputReducer()
        do {
            let attachment = try await connection.attach(terminalID: terminalID) { [weak self] event in
                Task { @MainActor in self?.handle(event) }
            }
            self.attachment = attachment
            if case .attaching = phase { phase = .attached }
        } catch {
            phase = .failed(CloudSessionFailure.classify(error, stage: .link))
        }
    }

    /// The tunnel is not ready, so there is no connection to attach through.
    public func markTunnelUnavailable() {
        phase = .failed(CloudSessionFailure(kind: .tunnel, detail: "tunnel not ready"))
    }

    /// Bytes the surface produced (typing, paste, mouse reports).
    public func sendInput(_ data: Data) {
        attachment?.send(data)
    }

    /// The surface's natural grid changed.
    public func reportGrid(cols: Int, rows: Int) {
        attachment?.resize(cols: cols, rows: rows)
    }

    /// End the attachment when the screen goes away.
    public func detach() {
        attachment?.detach()
        attachment = nil
    }

    private func handle(_ event: CloudTerminalOutputEvent) {
        if case .attaching = phase { phase = .attached }
        if case .exited = event { phase = .exited }
        for action in reducer.reduce(event) { apply(action) }
    }

    private func apply(_ action: CloudTerminalOutputReducer.Action) {
        guard let surface else {
            pending.append(action)
            return
        }
        switch action {
        case .applyGrid(let cols, let rows):
            surface.applyGrid(cols: cols, rows: rows)
        case .write(let data):
            surface.writeOutput(data)
        case .exited:
            phase = .exited
        }
    }
}
#endif
