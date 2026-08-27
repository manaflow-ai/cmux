import Foundation
import Testing
@testable import CMUXMobileCore

/// Every installed iOS bundle owns one pairing URL scheme. Parsers accept only
/// schemes whose release or development lane can be classified for account
/// preflight, while installed builds still register their exact bundle scheme.
@Suite struct CmxPairingURLSchemeTests {
    @Test func everyInstalledBundleEmitsItsOwnScheme() {
        #expect(
            CmxPairingURLScheme(
                iOSBundleIdentifier: "dev.cmux.app.internal"
            )?.rawValue == "cmux-ios-dev.cmux.app.internal"
        )
        #expect(
            CmxPairingURLScheme(
                iOSBundleIdentifier: "dev.cmux.app.demo"
            )?.rawValue == "cmux-ios-dev.cmux.app.demo"
        )
        #expect(
            CmxPairingURLScheme(
                iOSBundleIdentifier: "dev.cmux.ios.feature-a"
            )?.rawValue == "cmux-ios-dev.cmux.ios.feature-a"
        )
    }

    @Test func invalidIdentityDoesNotFallBackToAnotherApp() {
        #expect(CmxPairingURLScheme(iOSBundleIdentifier: "") == nil)
        #expect(CmxPairingURLScheme(iOSBundleIdentifier: "invalid bundle") == nil)
        #expect(
            CmxPairingURLScheme(
                iOSBundleIdentifier: "dev.cmux.app.unrecognized"
            ) == nil
        )
        #if !os(iOS)
        #expect(
            CmxPairingURLSchemeResolver(
                currentIOSBundleIdentifier: nil,
                targetIOSBundleIdentifier: nil,
                macInstanceTag: "invalid tag",
                isDevelopmentBuild: true
            ).resolved == nil
        )
        #endif
    }

    #if !os(iOS)
    @Test func untaggedDebugMacTargetsDefaultDebugIOSBundle() {
        #if DEBUG
        #expect(
            CmxPairingURLSchemeResolver(
                currentIOSBundleIdentifier: nil,
                targetIOSBundleIdentifier: nil,
                macInstanceTag: nil,
                isDevelopmentBuild: true
            ).resolved?.rawValue == "cmux-ios-dev.cmux.ios"
        )
        #endif
    }

    @Test func untaggedMacBuildChannelsResolveDistinctExactBundles() {
        #expect(
            CmxPairingURLSchemeResolver(
                currentIOSBundleIdentifier: nil,
                targetIOSBundleIdentifier: nil,
                macInstanceTag: nil,
                isDevelopmentBuild: true
            ).resolved?.rawValue == "cmux-ios-dev.cmux.ios"
        )
        #expect(
            CmxPairingURLSchemeResolver(
                currentIOSBundleIdentifier: nil,
                targetIOSBundleIdentifier: nil,
                macInstanceTag: nil,
                isDevelopmentBuild: false
            ).resolved?.rawValue == "cmux-ios-com.cmux.app"
        )
    }

    @Test func macCanExplicitlyTargetEveryReleaseLane() {
        for bundleIdentifier in [
            "com.cmux.app",
            "dev.cmux.app.beta",
            "dev.cmux.app.internal",
            "dev.cmux.app.demo",
        ] {
            #expect(
                CmxPairingURLSchemeResolver(
                    currentIOSBundleIdentifier: nil,
                    targetIOSBundleIdentifier: bundleIdentifier,
                    macInstanceTag: nil,
                    isDevelopmentBuild: false
                ).resolved?.rawValue
                    == "cmux-ios-\(bundleIdentifier)"
            )
        }
    }
    #endif

    @Test func parserAcceptsNamespacedSchemes() {
        #expect(CmxPairingURLScheme(rawValue: "cmux-ios-dev.cmux.app.internal") != nil)
        #expect(CmxPairingURLScheme(rawValue: "cmux-ios-dev.cmux.app.demo") != nil)
        #expect(CmxPairingURLScheme(rawValue: "CMUX-IOS-DEV.CMUX.IOS.FEATURE-A") != nil)
        // Old QR codes remain scannable inside an already-open app. New builds
        // do not register these shared schemes with iOS.
        #expect(CmxPairingURLScheme(rawValue: "cmux-ios") != nil)
        #expect(CmxPairingURLScheme(rawValue: "cmux-ios-dev") != nil)
    }

    @Test func parserRejectsForeignSchemes() {
        #expect(CmxPairingURLScheme(rawValue: nil) == nil)
        #expect(CmxPairingURLScheme(rawValue: "") == nil)
        #expect(CmxPairingURLScheme(rawValue: "https") == nil)
        #expect(CmxPairingURLScheme(rawValue: "cmux-ios-*") == nil)
    }

    @Test func channelClassificationRecognizesOnlyAuthoritativeLanes() throws {
        for bundleIdentifier in [
            "com.cmux.app",
            "dev.cmux.app.beta",
            "dev.cmux.app.internal",
            "dev.cmux.app.demo",
        ] {
            let scheme = try #require(
                CmxPairingURLScheme(
                    iOSBundleIdentifier: bundleIdentifier
                )
            )
            #expect(scheme.isRelease)
            #expect(!scheme.isDevelopment)
        }
        let development = try #require(
            CmxPairingURLScheme(
                iOSBundleIdentifier: "dev.cmux.ios.feature-a"
            )
        )
        #expect(development.isDevelopment)
        #expect(!development.isRelease)
        #expect(CmxPairingURLScheme(rawValue: "cmux-ios-dev.cmux.app.unrecognized") == nil)
    }

    @Test func prefixCheckAcceptsNamespacedSchemesAndRejectsOthers() {
        #expect(CmxPairingURLScheme(urlString:
            "cmux-ios-dev.cmux.app.internal://attach?v=2&r=100.64.0.5:58465"
        ) != nil)
        #expect(CmxPairingURLScheme(urlString:
            "CMUX-IOS-DEV.CMUX.IOS.FEATURE-A://attach?v=2"
        ) != nil)
        #expect(CmxPairingURLScheme(urlString: "cmux-ios://attach?v=2") != nil)
        #expect(CmxPairingURLScheme(urlString: "cmux-ios-dev://attach?v=2") != nil)
        #expect(CmxPairingURLScheme(urlString: "https://example.com") == nil)
        #expect(CmxPairingURLScheme(urlString: "cmux-ios-dev.cmux.app.internal") == nil)
    }
}
