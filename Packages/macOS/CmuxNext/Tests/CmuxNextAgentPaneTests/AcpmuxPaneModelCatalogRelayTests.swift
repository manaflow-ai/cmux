import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The model picker reads acpmux's model catalog (webviews direct.ts `modelCatalog`: `catalog.get`,
/// and `catalog.refresh` first on Refresh models). The relay did not list either, so it refused
/// every read as `transport.method_refused` (Leo's NIGHTLY, 2026-11-21), and the picker never
/// showed a model the public feed added. cmux-agent-pane-policy `tests/typescript.rs` holds the
/// list to every method direct.ts sends.
@Suite
struct AcpmuxPaneModelCatalogRelayTests {
    private static func frame(_ method: String, _ params: [String: Any] = [:]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": 1, "method": method, "params": params]
    }

    @Test func thePickersCatalogReadsAreRelayed() {
        for method in ["catalog.get", "catalog.refresh"] {
            #expect(AcpmuxPaneMethods.requests.contains(method), "\(method) is not in AcpmuxPaneMethods.requests")
            #expect(!AcpmuxPaneMethods.breaksParamsRule(Self.frame(method), modeFields: nil), "\(method) {} breaks the params rule")
        }
    }

    @Test func aCatalogReadTakesNoParams() {
        #expect(AcpmuxPaneMethods.breaksParamsRule(Self.frame("catalog.get", ["url": "https://example.invalid"]), modeFields: nil))
        #expect(AcpmuxPaneMethods.breaksParamsRule(Self.frame("catalog.refresh", ["force": true]), modeFields: nil))
    }
}
