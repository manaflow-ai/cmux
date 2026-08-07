import CmuxFoundation
import Foundation
import Testing

@testable import CmuxSidebar

@Suite("CustomSidebarFocusScope arming and locking")
struct CustomSidebarFocusScopeTests {
    private func loopbackScope(_ urlString: String) -> CustomSidebarFocusScope? {
        CustomSidebarFocusScope(source: .remote(URL(string: urlString)!))
    }

    @Test("a local document arms on its standardized file url")
    func documentArms() {
        let source = CustomSidebarWebSource.document(
            URL(fileURLWithPath: "/Users/someone/.config/cmux/sidebars/./board.html")
        )
        #expect(
            CustomSidebarFocusScope(source: source)
                == .document(URL(fileURLWithPath: "/Users/someone/.config/cmux/sidebars/board.html"))
        )
    }

    @Test("a document source carrying a non-file URL never arms")
    func nonFileDocumentDoesNotArm() {
        let source = CustomSidebarWebSource.document(URL(string: "https://example.com/board.html")!)
        #expect(CustomSidebarFocusScope(source: source) == nil)
    }

    @Test(
        "a literal loopback page arms",
        arguments: [
            "http://127.0.0.1:8787/",
            "http://127.0.0.1/",
            "https://127.0.0.1:8443/panel",
            "http://127.4.5.6:3000/",
            "http://[::1]:5173/",
        ]
    )
    func loopbackArms(urlString: String) {
        #expect(loopbackScope(urlString) != nil)
    }

    // The whole point of the address-literal rule: a name is whatever the resolver says it is
    // today, so a sidebar pointed at one must not be handed a native capability.
    @Test(
        "a name or a public address never arms",
        arguments: [
            "http://localhost:8787/",
            "http://localhost.localdomain:8787/",
            "https://cmux.local/",
            "https://example.com/",
            "http://10.0.0.1/",
            "http://192.168.1.2:8787/",
            "http://127.1/",
            "http://2130706433/",
            "http://0x7f.0.0.1/",
            "http://127.0.0.1.example.com/",
            "ftp://127.0.0.1/",
        ]
    )
    func unqualifiedSourcesDoNotArm(urlString: String) {
        #expect(loopbackScope(urlString) == nil)
    }

    @Test("a loopback scope permits navigation inside its own origin")
    func loopbackPermitsSameOrigin() throws {
        let scope = try #require(loopbackScope("http://127.0.0.1:8787/index.html"))
        #expect(scope.permitsNavigation(to: URL(string: "http://127.0.0.1:8787/other?q=1"), isMainFrame: true))
    }

    @Test(
        "a loopback scope cancels a main-frame hop that leaves the origin",
        arguments: [
            "http://127.0.0.1:9999/",
            "https://127.0.0.1:8787/",
            "http://127.0.0.2:8787/",
            "http://example.com/",
            "file:///Users/someone/.config/cmux/sidebars/board.html",
        ]
    )
    func loopbackCancelsCrossOrigin(target: String) throws {
        let scope = try #require(loopbackScope("http://127.0.0.1:8787/index.html"))
        #expect(!scope.permitsNavigation(to: URL(string: target), isMainFrame: true))
    }

    // A subframe cannot reach the bridge (dispatch requires the main frame), and a sidebar that
    // embeds something is a legitimate design, so the lock stays off subframes.
    @Test("subframe navigation is unconstrained")
    func subframesAreFree() throws {
        let scope = try #require(loopbackScope("http://127.0.0.1:8787/"))
        #expect(scope.permitsNavigation(to: URL(string: "https://example.com/embed"), isMainFrame: false))
    }

    @Test("a document scope pins the main frame to exactly its own file")
    func documentPinsToItsOwnFile() throws {
        let fileURL = URL(fileURLWithPath: "/sidebars/board.html")
        let scope = try #require(CustomSidebarFocusScope(source: .document(fileURL)))
        #expect(scope.permitsNavigation(to: fileURL, isMainFrame: true))
        #expect(!scope.permitsNavigation(to: URL(fileURLWithPath: "/sidebars/other.html"), isMainFrame: true))
        #expect(!scope.permitsNavigation(to: URL(string: "http://127.0.0.1:8787/"), isMainFrame: true))
        #expect(!scope.permitsNavigation(to: nil, isMainFrame: true))
    }

    @Test("a loopback scope dispatches only for its own main frame")
    func loopbackDispatchChecks() throws {
        let scope = try #require(loopbackScope("http://127.0.0.1:8787/index.html"))
        let current = URL(string: "http://127.0.0.1:8787/index.html")

        #expect(scope.permitsDispatch(
            isMainFrame: true,
            frameOriginScheme: "http",
            frameOriginHost: "127.0.0.1",
            frameOriginPort: 8787,
            webViewURL: current
        ))
        #expect(!scope.permitsDispatch(
            isMainFrame: false,
            frameOriginScheme: "http",
            frameOriginHost: "127.0.0.1",
            frameOriginPort: 8787,
            webViewURL: current
        ))
        #expect(!scope.permitsDispatch(
            isMainFrame: true,
            frameOriginScheme: "https",
            frameOriginHost: "example.com",
            frameOriginPort: 443,
            webViewURL: current
        ))
        // The frame can claim the right origin while the view has already moved on; both have to
        // agree, so a redirect the delegate never saw still fails here.
        #expect(!scope.permitsDispatch(
            isMainFrame: true,
            frameOriginScheme: "http",
            frameOriginHost: "127.0.0.1",
            frameOriginPort: 8787,
            webViewURL: URL(string: "https://example.com/")
        ))
        #expect(!scope.permitsDispatch(
            isMainFrame: true,
            frameOriginScheme: "http",
            frameOriginHost: "127.0.0.1",
            frameOriginPort: 8787,
            webViewURL: nil
        ))
    }

    // WebKit reports port 0 for a scheme's default port, so an armed `http://127.0.0.1/` sidebar
    // would never dispatch if the default were not filled in on both sides.
    @Test("a default port reported as zero still matches the armed origin")
    func defaultPortDispatches() throws {
        let scope = try #require(loopbackScope("http://127.0.0.1/"))
        #expect(scope.permitsDispatch(
            isMainFrame: true,
            frameOriginScheme: "http",
            frameOriginHost: "127.0.0.1",
            frameOriginPort: 0,
            webViewURL: URL(string: "http://127.0.0.1/")
        ))
    }

    @Test("a document dispatches only while the view still shows that file")
    func documentDispatchChecks() throws {
        let fileURL = URL(fileURLWithPath: "/sidebars/board.html")
        let scope = try #require(CustomSidebarFocusScope(source: .document(fileURL)))

        #expect(scope.permitsDispatch(
            isMainFrame: true,
            frameOriginScheme: "file",
            frameOriginHost: "",
            frameOriginPort: 0,
            webViewURL: fileURL
        ))
        #expect(!scope.permitsDispatch(
            isMainFrame: true,
            frameOriginScheme: "file",
            frameOriginHost: "",
            frameOriginPort: 0,
            webViewURL: URL(fileURLWithPath: "/sidebars/other.html")
        ))
        #expect(!scope.permitsDispatch(
            isMainFrame: true,
            frameOriginScheme: "http",
            frameOriginHost: "127.0.0.1",
            frameOriginPort: 8787,
            webViewURL: fileURL
        ))
    }
}
