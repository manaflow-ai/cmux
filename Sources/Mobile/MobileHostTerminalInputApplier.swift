import CMUXMobileCore
import CmuxTerminal
import Foundation

/// The one place phone input reaches a terminal.
///
/// Every PTY-writing phone path (the IRX input lane, the legacy-dialect input
/// lane, and the `terminal.input` / `paste` / `paste_image` / `scroll` /
/// `mouse` RPCs) asks ``admit(_:surfaceID:)`` before writing and reports the
/// write with ``complete(_:result:)``. For input that carries a
/// ``MobileTerminalInputDelivery``, the shared ledger then guarantees each unit
/// is written once, in order, and only to the terminal its stream is bound to,
/// whichever path or connection delivers it. Input without an identity (an
/// older phone) is written as before.
@MainActor
final class MobileHostTerminalInputApplier {
    static let shared = MobileHostTerminalInputApplier()

    enum Admission: Equatable {
        /// Write the input now, then call ``complete(_:result:)``.
        case proceed
        /// Do not write: the unit was already applied, arrived out of order,
        /// or names another terminal. Return this acknowledgement instead.
        case answer(MobileTerminalInputAcknowledgement)
    }

    private var ledger: MobileTerminalInputLedger
    private let now: () -> Date

    init(
        ledger: MobileTerminalInputLedger = MobileTerminalInputLedger(),
        now: @escaping () -> Date = Date.init
    ) {
        self.ledger = ledger
        self.now = now
    }

    func admit(_ delivery: MobileTerminalInputDelivery?, surfaceID: UUID) -> Admission {
        guard let delivery else { return .proceed }
        guard delivery.surfaceID == surfaceID else {
            // The unit was typed into another terminal than the one this
            // request or lane addresses. Never write it here.
            return .answer(Self.acknowledgement(.surfaceMismatch, delivery))
        }
        switch ledger.admit(delivery, now: now()) {
        case .apply:
            return .proceed
        case .duplicate(let appliedThrough):
            return .answer(MobileTerminalInputAcknowledgement(
                status: .duplicate,
                streamID: delivery.streamID,
                sequence: appliedThrough
            ))
        case .gap(let expected):
            return .answer(MobileTerminalInputAcknowledgement(
                status: .gap,
                streamID: delivery.streamID,
                sequence: delivery.sequence,
                expected: expected
            ))
        case .surfaceMismatch:
            return .answer(Self.acknowledgement(.surfaceMismatch, delivery))
        }
    }

    /// Records the terminal's answer to a write that ``admit(_:surfaceID:)``
    /// allowed. Only accepted input advances the stream, so a unit refused
    /// for a full queue is written again when the phone resends it.
    @discardableResult
    func complete(
        _ delivery: MobileTerminalInputDelivery?,
        result: TerminalSurface.InputSendResult
    ) -> MobileTerminalInputAcknowledgement? {
        guard let delivery else { return nil }
        switch result {
        case .sent, .queued:
            ledger.recordApplied(delivery, now: now())
            return Self.acknowledgement(.applied, delivery)
        case .inputQueueFull:
            return Self.acknowledgement(.busy, delivery)
        case .surfaceUnavailable, .processExited:
            return Self.acknowledgement(.terminalUnavailable, delivery)
        }
    }

    /// The host admitted the unit but cannot use it (an image it could not
    /// store). It is consumed without writing so later units still apply,
    /// and a resend of it is answered as a duplicate instead of written.
    @discardableResult
    func reject(_ delivery: MobileTerminalInputDelivery?) -> MobileTerminalInputAcknowledgement? {
        guard let delivery else { return nil }
        ledger.recordApplied(delivery, now: now())
        return Self.acknowledgement(.rejected, delivery)
    }

    /// Acknowledges a write the terminal cannot refuse (scroll, mouse).
    @discardableResult
    func completeAccepted(_ delivery: MobileTerminalInputDelivery?) -> MobileTerminalInputAcknowledgement? {
        complete(delivery, result: .sent)
    }

    /// The terminal the unit names no longer exists on this Mac.
    static func unavailable(_ delivery: MobileTerminalInputDelivery?) -> MobileTerminalInputAcknowledgement? {
        delivery.map { acknowledgement(.terminalUnavailable, $0) }
    }

    private static func acknowledgement(
        _ status: MobileTerminalInputAcknowledgement.Status,
        _ delivery: MobileTerminalInputDelivery
    ) -> MobileTerminalInputAcknowledgement {
        MobileTerminalInputAcknowledgement(
            status: status,
            streamID: delivery.streamID,
            sequence: delivery.sequence
        )
    }
}
