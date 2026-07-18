import CmuxTerminalBackend
import Foundation
import Testing

@Suite("Strict topology projection")
struct TopologyProjectionTests {
    @Test("contiguous delta advances value and revision together")
    func contiguousDelta() throws {
        let authority = authority()
        var projection = TopologyProjection(
            snapshot: snapshot(authority: authority, revision: 4),
            value: ["one"]
        )
        try projection.apply(delta(authority: authority, base: 4, revision: 5)) { value, _ in
            value + ["two"]
        }
        #expect(projection.revision == 5)
        #expect(projection.value == ["one", "two"])
    }

    @Test("failed reducer exposes neither candidate state nor revision")
    func reducerFailureIsAtomic() {
        enum Failure: Error { case expected }
        let authority = authority()
        var projection = TopologyProjection(
            snapshot: snapshot(authority: authority, revision: 4),
            value: ["one"]
        )
        #expect(throws: Failure.expected) {
            try projection.apply(delta(authority: authority, base: 4, revision: 5)) { _, _ in
                throw Failure.expected
            }
        }
        #expect(projection.revision == 4)
        #expect(projection.value == ["one"])
    }

    @Test("revision gap is rejected before reducer runs")
    func revisionGap() {
        let authority = authority()
        var reduced = false
        var projection = TopologyProjection(
            snapshot: snapshot(authority: authority, revision: 4),
            value: ["one"]
        )
        #expect(throws: TopologyProjectionError.revisionGap(expectedBase: 4, actualBase: 6)) {
            try projection.apply(delta(authority: authority, base: 6, revision: 7)) { value, _ in
                reduced = true
                return value
            }
        }
        #expect(!reduced)
    }

    @Test("same session from replacement daemon still requires resnapshot")
    func daemonReplacement() {
        let authority = authority()
        let replacement = BackendAuthority(
            daemonInstanceID: DaemonInstanceID(rawValue: UUID()),
            sessionID: authority.sessionID
        )
        var projection = TopologyProjection(
            snapshot: snapshot(authority: authority, revision: 9),
            value: 1
        )
        #expect(throws: TopologyProjectionError.daemonChanged(
            expected: authority.daemonInstanceID,
            actual: replacement.daemonInstanceID
        )) {
            try projection.apply(delta(authority: replacement, base: 9, revision: 10)) { value, _ in
                value + 1
            }
        }
        #expect(projection.revision == 9)
        #expect(projection.value == 1)
    }

    @Test("revision wrap is never accepted")
    func revisionWrap() {
        let authority = authority()
        var projection = TopologyProjection(
            snapshot: snapshot(authority: authority, revision: UInt64.max),
            value: 1
        )
        #expect(throws: TopologyProjectionError.invalidRevision(
            base: UInt64.max,
            revision: 0
        )) {
            try projection.apply(
                delta(authority: authority, base: UInt64.max, revision: 0)
            ) { value, _ in value + 1 }
        }
    }

    private func authority() -> BackendAuthority {
        BackendAuthority(
            daemonInstanceID: DaemonInstanceID(rawValue: UUID()),
            sessionID: SessionID(rawValue: UUID())
        )
    }

    private func snapshot(authority: BackendAuthority, revision: UInt64) -> TopologySnapshot {
        TopologySnapshot(
            authority: authority,
            revision: revision,
            topology: try! CanonicalTopology(workspaces: [])
        )
    }

    private func delta(
        authority: BackendAuthority,
        base: UInt64,
        revision: UInt64
    ) -> TopologyDelta {
        TopologyDelta(
            authority: authority,
            baseRevision: base,
            revision: revision,
            operation: .workspaceRenamed,
            targets: try! TopologyTargets(),
            replacement: try! CanonicalTopology(workspaces: [])
        )
    }
}
