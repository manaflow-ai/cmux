import Foundation
import Testing
import WebKit
import CmuxBrowser

@MainActor
@Suite
struct BrowserEngineParityChecklistTests {
    private let checklist = BrowserEngineParityChecklist.standard

    @Test func everyEntryIsOneDistinctCapability() {
        let entries = checklist.entries
        #expect(Set(entries.map(\.name)).count == entries.count)
        var seen: BrowserEngineCapabilities = []
        for entry in entries {
            #expect(entry.capability.rawValue.nonzeroBitCount == 1, "\(entry.name) is not a single capability")
            #expect(seen.isDisjoint(with: entry.capability), "\(entry.name) is listed twice")
            seen.formUnion(entry.capability)
        }
    }

    @Test func everyGapNamesItsOwnerAndEveryExceptionItsReason() {
        for entry in checklist.entries {
            for engine in BrowserEngineKind.allCases {
                switch entry.support(for: engine) {
                case .supported: break
                case let .gap(owner): #expect(!owner.isEmpty, "\(engine) \(entry.name) gap has no owner")
                case let .notApplicable(reason): #expect(!reason.isEmpty, "\(engine) \(entry.name) has no reason")
                }
            }
        }
    }

    /// WebKit pages declare exactly what the checklist marks supported.
    /// CmuxCEF's adapter tests make the same call for Chromium.
    @Test func webKitDeclaresExactlyItsChecklistColumn() {
        let page = WebKitBrowserPage(webView: makeWebView())
        #expect(checklist.mismatches(declared: page.capabilities, engine: .webkit) == [])
        #expect(page.capabilities == checklist.supported(by: .webkit))
    }

    @Test func mismatchesNameEachDifference() {
        let wanted = checklist.supported(by: .webkit)
        #expect(checklist.mismatches(declared: wanted, engine: .webkit).isEmpty)

        let dropped = checklist.mismatches(
            declared: wanted.subtracting(.snapshots), engine: .webkit
        )
        #expect(dropped == ["webkit does not declare snapshots, which the checklist marks supported"])

        let gained = checklist.mismatches(
            declared: wanted.union(.trustedInput), engine: .webkit
        )
        #expect(gained.count == 1)
        #expect(gained.first?.hasPrefix("webkit declares trustedInput") == true)

        let unlisted = BrowserEngineCapabilities(rawValue: 1 << 31)
        #expect(!checklist.allCapabilities.contains(unlisted))
        let unknown = checklist.mismatches(declared: wanted.union(unlisted), engine: .webkit)
        #expect(unknown == ["webkit declares capability bits 0x80000000 the checklist does not list"])
    }

    /// A capability an engine lacks must refuse its operation with
    /// `.unsupported`, and one it declares must not: an adapter cannot claim
    /// a capability while its method is still a stub.
    @Test func webKitOperationsMatchDeclaredCapabilities() async {
        let page = WebKitBrowserPage(webView: makeWebView())
        let probes: [(String, BrowserEngineCapabilities, @MainActor () async throws -> Void)] = [
            ("devToolsProtocol", .devToolsProtocol, {
                _ = try await page.sendDevToolsProtocolMessage(method: "Browser.getVersion", params: nil)
            }),
            ("trustedInput", .trustedInput, { try await page.dispatchInput(.insertText("a")) }),
        ]
        for (name, capability, probe) in probes {
            var refused = false
            do { try await probe() } catch BrowserEngineError.unsupported { refused = true } catch {}
            #expect(refused == !page.capabilities.contains(capability), "\(name): refused=\(refused)")
        }
    }

    @Test func gapsAreReportedPerEngine() {
        let webkit = checklist.gaps(of: .webkit)
        for (name, owner) in webkit {
            let entry = checklist.entries.first { $0.name == name }
            #expect(entry?.webkit == .gap(owner: owner))
        }
        #expect(!checklist.supported(by: .chromium).isEmpty)
    }

    private func makeWebView() -> WKWebView {
        WKWebView(frame: NSRect(x: 0, y: 0, width: 320, height: 240), configuration: WKWebViewConfiguration())
    }
}
