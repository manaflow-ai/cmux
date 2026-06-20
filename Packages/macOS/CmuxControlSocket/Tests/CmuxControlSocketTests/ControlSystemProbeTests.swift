import Testing
@testable import CmuxControlSocket

@Suite("ControlSystemProbe")
struct ControlSystemProbeTests {
    /// `ping()` is the byte-faithful `{"pong": true}` acknowledgement, always ok.
    @Test func pingIsPongTrue() {
        #expect(ControlSystemProbe().ping() == .ok(.object(["pong": .bool(true)])))
    }

    /// `capabilities(...)` carries the protocol banner, the live socket_path /
    /// access_mode strings verbatim, and `version` as integer 2 (not a double),
    /// matching the legacy `v2Capabilities` wire shape.
    @Test func capabilitiesCarriesBannerAndLiveState() throws {
        let result = ControlSystemProbe().capabilities(
            socketPath: "/tmp/cmux-test.sock",
            accessModeRawValue: "cmux_only"
        )
        guard case .ok(.object(let payload)) = result else {
            Issue.record("expected an ok object result, got \(result)")
            return
        }
        #expect(payload["protocol"] == .string("cmux-socket"))
        #expect(payload["version"] == .int(2))
        #expect(payload["socket_path"] == .string("/tmp/cmux-test.sock"))
        #expect(payload["access_mode"] == .string("cmux_only"))
    }

    /// The advertised `methods` array is the manifest's catalog emitted sorted
    /// with no duplicates (the legacy `methods.sorted()` contract). In a DEBUG
    /// build it is the union of release + debug methods; in release it is just
    /// the release methods. Either way it equals the corresponding sorted set,
    /// which is what this assertion pins regardless of build config.
    @Test func capabilitiesMethodsAreSortedManifestUnion() {
        let result = ControlSystemProbe().capabilities(socketPath: "s", accessModeRawValue: "m")
        guard case .ok(.object(let payload)) = result,
              case .array(let methods)? = payload["methods"] else {
            Issue.record("expected methods array, got \(result)")
            return
        }
        let names: [String] = methods.compactMap {
            if case .string(let value) = $0 { return value }
            return nil
        }
        #expect(names.count == methods.count, "every method entry is a JSON string")
        #expect(names == names.sorted(), "methods are emitted sorted")

        let manifest = ControlCapabilitiesManifest.frozen
#if DEBUG
        let expected = (manifest.releaseMethods + manifest.debugMethods).sorted()
#else
        let expected = manifest.releaseMethods.sorted()
#endif
        #expect(names == expected)
    }

    /// A custom manifest flows through unchanged, proving the catalog is
    /// injected (not a hardcoded static), and the empty live strings round-trip.
    @Test func capabilitiesHonorsInjectedManifest() {
        let probe = ControlSystemProbe(
            manifest: ControlCapabilitiesManifest(releaseMethods: ["b.x", "a.y"], debugMethods: [])
        )
        let result = probe.capabilities(socketPath: "", accessModeRawValue: "")
        guard case .ok(.object(let payload)) = result,
              payload["methods"] == .array([.string("a.y"), .string("b.x")]) else {
            Issue.record("expected sorted injected methods, got \(result)")
            return
        }
        #expect(payload["socket_path"] == .string(""))
        #expect(payload["access_mode"] == .string(""))
    }
}
