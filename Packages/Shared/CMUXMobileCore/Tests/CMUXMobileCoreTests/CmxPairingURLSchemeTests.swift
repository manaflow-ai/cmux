import Foundation
import Testing
@testable import CMUXMobileCore

/// Every installed iOS bundle owns one pairing URL scheme. Parsers accept any
/// syntactically valid cmux pairing scheme so an in-app scanner remains
/// forward-compatible without multiple installed builds claiming one scheme.
@Suite struct CmxPairingURLSchemeTests {
    @Test func everyInstalledBundleEmitsItsOwnScheme() {
        #expect(
            CmxPairingURLScheme.scheme(
                forIOSBundleIdentifier: "dev.cmux.app.internal"
            ) == "cmux-ios-dev.cmux.app.internal"
        )
        #expect(
            CmxPairingURLScheme.scheme(
                forIOSBundleIdentifier: "dev.cmux.app.demo"
            ) == "cmux-ios-dev.cmux.app.demo"
        )
        #expect(
            CmxPairingURLScheme.scheme(
                forIOSBundleIdentifier: "dev.cmux.ios.feature-a"
            ) == "cmux-ios-dev.cmux.ios.feature-a"
        )
    }

    @Test func invalidIdentityDoesNotFallBackToAnotherApp() {
        #expect(CmxPairingURLScheme.scheme(forIOSBundleIdentifier: "") == nil)
        #expect(CmxPairingURLScheme.scheme(forIOSBundleIdentifier: "invalid bundle") == nil)
        #if !os(iOS)
        #expect(
            CmxPairingURLScheme.resolvedCurrent(
                environment: ["CMUX_TAG": "invalid tag"]
            ) == nil
        )
        #endif
    }

    @Test func parserAcceptsNamespacedSchemes() {
        #expect(CmxPairingURLScheme.isPairingScheme("cmux-ios-dev.cmux.app.internal"))
        #expect(CmxPairingURLScheme.isPairingScheme("cmux-ios-dev.cmux.app.demo"))
        #expect(CmxPairingURLScheme.isPairingScheme("CMUX-IOS-DEV.CMUX.IOS.FEATURE-A"))
        // Old QR codes remain scannable inside an already-open app. New builds
        // do not register these shared schemes with iOS.
        #expect(CmxPairingURLScheme.isPairingScheme("cmux-ios"))
        #expect(CmxPairingURLScheme.isPairingScheme("cmux-ios-dev"))
    }

    @Test func parserRejectsForeignSchemes() {
        #expect(!CmxPairingURLScheme.isPairingScheme(nil))
        #expect(!CmxPairingURLScheme.isPairingScheme(""))
        #expect(!CmxPairingURLScheme.isPairingScheme("https"))
        #expect(!CmxPairingURLScheme.isPairingScheme("cmux-ios-*"))
    }

    @Test func prefixCheckAcceptsNamespacedSchemesAndRejectsOthers() {
        #expect(CmxPairingURLScheme.hasPairingScheme(
            "cmux-ios-dev.cmux.app.internal://attach?v=2&r=100.64.0.5:58465"
        ))
        #expect(CmxPairingURLScheme.hasPairingScheme(
            "CMUX-IOS-DEV.CMUX.IOS.FEATURE-A://attach?v=2"
        ))
        #expect(CmxPairingURLScheme.hasPairingScheme("cmux-ios://attach?v=2"))
        #expect(CmxPairingURLScheme.hasPairingScheme("cmux-ios-dev://attach?v=2"))
        #expect(!CmxPairingURLScheme.hasPairingScheme("https://example.com"))
        #expect(!CmxPairingURLScheme.hasPairingScheme("cmux-ios-dev.cmux.app.internal"))
    }
}
