import CoreGraphics
import Foundation
import Testing
@testable import CmuxSettings

@Suite("WindowOpenSizeSettings")
struct WindowOpenSizeSettingsTests {
    private static let persisted = CGRect(x: 120, y: 80, width: 1_440, height: 900)
    private static let restored = CGRect(x: 10, y: 20, width: 1_280, height: 720)
    private static let sourceWindow = CGRect(x: 0, y: 0, width: 1_100, height: 760)

    // MARK: fixedContentSize

    @Test func fixedContentSizeIsNilWhenDisabled() {
        let policy = WindowOpenSizeSettings(openAtFixedSize: false, width: 800, height: 600)
        #expect(policy.fixedContentSize() == nil)
    }

    @Test func fixedContentSizeReturnsConfiguredSizeWhenEnabled() {
        let policy = WindowOpenSizeSettings(openAtFixedSize: true, width: 800, height: 600)
        #expect(policy.fixedContentSize() == CGSize(width: 800, height: 600))
    }

    @Test func fixedContentSizeClampsOutOfRangeDimensions() {
        let tooSmall = WindowOpenSizeSettings(openAtFixedSize: true, width: 10, height: 10)
        #expect(tooSmall.fixedContentSize() == CGSize(
            width: WindowOpenSizeSettings.minimumDimension,
            height: WindowOpenSizeSettings.minimumDimension
        ))

        let tooBig = WindowOpenSizeSettings(openAtFixedSize: true, width: 99_999, height: 99_999)
        #expect(tooBig.fixedContentSize() == CGSize(
            width: WindowOpenSizeSettings.maximumDimension,
            height: WindowOpenSizeSettings.maximumDimension
        ))
    }

    // MARK: read(from:)

    @Test func readFallsBackToDefaultsWhenUnset() throws {
        let defaults = try #require(UserDefaults(suiteName: "WindowOpenSizeSettingsTests.unset"))
        defaults.removePersistentDomain(forName: "WindowOpenSizeSettingsTests.unset")
        let policy = WindowOpenSizeSettings.read(from: defaults)
        #expect(policy.openAtFixedSize == WindowOpenSizeSettings.defaultOpenAtFixedSize)
        #expect(policy.width == WindowOpenSizeSettings.defaultWidth)
        #expect(policy.height == WindowOpenSizeSettings.defaultHeight)
    }

    @Test func readReflectsStoredValues() throws {
        let defaults = try #require(UserDefaults(suiteName: "WindowOpenSizeSettingsTests.stored"))
        defaults.removePersistentDomain(forName: "WindowOpenSizeSettingsTests.stored")
        defaults.set(true, forKey: WindowOpenSizeSettings.openAtFixedSizeStorageKey)
        defaults.set(1_280, forKey: WindowOpenSizeSettings.widthStorageKey)
        defaults.set(800, forKey: WindowOpenSizeSettings.heightStorageKey)
        let policy = WindowOpenSizeSettings.read(from: defaults)
        #expect(policy.fixedContentSize() == CGSize(width: 1_280, height: 800))
        defaults.removePersistentDomain(forName: "WindowOpenSizeSettingsTests.stored")
    }

    // MARK: precedence

    /// The core regression assertion: with the fixed-size option on, a new
    /// window opens at the configured size, NOT the persisted last-window
    /// geometry.
    @Test func resolverUsesFixedSizeOverPersistedGeometry() {
        let source = WindowOpenSizeSettings.resolveInitialFrameSource(
            fixedContentSize: CGSize(width: 1_280, height: 800),
            restoredFrame: nil,
            sourceWindowFrame: nil,
            persistedGeometryFrame: Self.persisted
        )
        #expect(source == .fixedSize(CGSize(width: 1_280, height: 800)))
    }

    /// Fixed size also overrides the spawned-from source window.
    @Test func resolverUsesFixedSizeOverSourceWindow() {
        let source = WindowOpenSizeSettings.resolveInitialFrameSource(
            fixedContentSize: CGSize(width: 1_280, height: 800),
            restoredFrame: nil,
            sourceWindowFrame: Self.sourceWindow,
            persistedGeometryFrame: nil
        )
        #expect(source == .fixedSize(CGSize(width: 1_280, height: 800)))
    }

    /// With the option off (nil fixed size), the persisted geometry still wins —
    /// existing restore-last-size behavior is unchanged.
    @Test func resolverKeepsPersistedGeometryWhenFixedSizeDisabled() {
        let source = WindowOpenSizeSettings.resolveInitialFrameSource(
            fixedContentSize: nil,
            restoredFrame: nil,
            sourceWindowFrame: nil,
            persistedGeometryFrame: Self.persisted
        )
        #expect(source == .persistedGeometry(Self.persisted))
    }

    /// Full session restore always wins, even with the fixed-size option on, so
    /// restoring a saved multi-window layout keeps each window's exact frame.
    @Test func resolverPrefersRestoredFrameOverFixedSize() {
        let source = WindowOpenSizeSettings.resolveInitialFrameSource(
            fixedContentSize: CGSize(width: 1_280, height: 800),
            restoredFrame: Self.restored,
            sourceWindowFrame: nil,
            persistedGeometryFrame: Self.persisted
        )
        #expect(source == .restored(Self.restored))
    }

    /// No signal at all → fall back to the built-in default size.
    @Test func resolverFallsBackToDefaultWhenNoSignal() {
        let source = WindowOpenSizeSettings.resolveInitialFrameSource(
            fixedContentSize: nil,
            restoredFrame: nil,
            sourceWindowFrame: nil,
            persistedGeometryFrame: nil
        )
        #expect(source == .fallbackDefault)
    }
}
