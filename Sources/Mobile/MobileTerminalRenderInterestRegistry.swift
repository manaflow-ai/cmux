import Foundation
import os

/// Which terminals each mobile connection is rendering, declared by the phone
/// through `mobile.terminal.view_set`.
///
/// Render-grid work is proportional to the surfaces it covers: each capture
/// exports the whole grid from Ghostty, diffs it and encodes it. A phone shows
/// one or a few terminals, so producing frames for every other surface on the
/// Mac spends CPU here and bandwidth on the way only for the phone to discard
/// them. Connections that never declare a view set (older phones) keep the
/// historical contract of receiving every surface.
///
/// Safe from any actor/queue. Entries are removed when the connection closes.
final class MobileTerminalRenderInterestRegistry: Sendable {
    static let shared = MobileTerminalRenderInterestRegistry()

    /// The surfaces the producer must capture.
    enum Scope: Equatable {
        /// At least one render-grid consumer has not declared a view set.
        case all
        case surfaces(Set<UUID>)

        func contains(_ surfaceID: UUID) -> Bool {
            switch self {
            case .all: true
            case .surfaces(let surfaceIDs): surfaceIDs.contains(surfaceID)
            }
        }
    }

    /// Scope before and after a mutation, so the producer can drop state for
    /// surfaces nobody watches and capture surfaces that just became visible.
    struct Change {
        let previous: Scope
        let current: Scope
    }

    private struct State {
        /// Connections subscribed to render grids; nil value = undeclared.
        var viewSetsByConnectionID: [UUID: Set<UUID>?] = [:]

        var scope: Scope {
            var union = Set<UUID>()
            for viewSet in viewSetsByConnectionID.values {
                guard let viewSet else { return .all }
                union.formUnion(viewSet)
            }
            return .surfaces(union)
        }
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Registers a render-grid subscriber. An existing declaration survives an
    /// idempotent re-subscribe.
    @discardableResult
    func registerSubscriber(connectionID: UUID) -> Change {
        mutate { state in
            if state.viewSetsByConnectionID[connectionID] == nil {
                state.viewSetsByConnectionID[connectionID] = .some(nil)
            }
        }
    }

    @discardableResult
    func setViewSet(_ surfaceIDs: Set<UUID>, connectionID: UUID) -> Change {
        mutate { $0.viewSetsByConnectionID[connectionID] = .some(surfaceIDs) }
    }

    @discardableResult
    func remove(connectionID: UUID) -> Change {
        mutate { $0.viewSetsByConnectionID.removeValue(forKey: connectionID) }
    }

    var scope: Scope {
        state.withLock { $0.scope }
    }

    /// Whether `connectionID` should receive frames for `surfaceID`.
    func wants(connectionID: UUID, surfaceID: UUID) -> Bool {
        state.withLock { state in
            guard let declared = state.viewSetsByConnectionID[connectionID],
                  let viewSet = declared else { return true }
            return viewSet.contains(surfaceID)
        }
    }

    private func mutate(_ body: (inout State) -> Void) -> Change {
        state.withLock { state in
            let previous = state.scope
            body(&state)
            return Change(previous: previous, current: state.scope)
        }
    }
}
