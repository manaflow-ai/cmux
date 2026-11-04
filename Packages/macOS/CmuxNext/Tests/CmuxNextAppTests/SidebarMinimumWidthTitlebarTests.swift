import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextDesignTokens
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// At the sidebar's narrowest width the titlebar row still fits every control side by side: the
/// traffic lights, the toolbar band (sidebar toggle, Back, Forward) and the sidebar's + (New
/// Workspace). Lawrence 2026-10-30 (messages 17576, 17584): at the old 160 pt minimum Forward drew
/// over the +; "not remove glyph but just make min width of sidebar bigger". A width saved below
/// the new minimum (an existing user's) comes back clamped.
@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarMinimumWidthTitlebarTests {
    /// A window root in a titled, full-size-content window, as the app shows it.
    func root(window suppliedWindow: NSWindow? = nil) -> (NSWindow, WindowRootView) {
        _ = NSApplication.shared
        let root = WindowRootView(sidebar: SidebarContainerView(model: SidebarModel()))
        let window = suppliedWindow ?? NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.contentView = root
        settle(root)
        return (window, root)
    }

    func settle(_ root: WindowRootView) {
        for _ in 0..<2 {
            root.needsLayout = true
            root.layoutSubtreeIfNeeded()
        }
    }

    /// The gap between Forward's trailing edge and the +'s leading edge, in the root's coordinates.
    func gapBeforePlus(_ root: WindowRootView) -> CGFloat {
        let forward = root.toolbarBand.convert(root.toolbarBand.forwardButton.frame, to: root)
        let sidebarView = root.sidebar.sidebarView
        let plus = sidebarView.convert(sidebarView.newButton.frame, to: root)
        return plus.minX - forward.maxX
    }

    @Test func restoringAWidthBelowTheTitlebarMinimumClampsItSoNothingOverlaps() {
        let (window, root) = root()
        defer { window.close() }
        // An existing user's saved width at the old minimum.
        root.sidebar.restore(width: 160, presentation: .shown)
        settle(root)
        #expect(gapBeforePlus(root) >= Metrics.space2)
        #expect(root.sidebar.sidebarView.newButton.frame.maxX <= root.sidebar.sidebarView.bounds.maxX)
    }

    @Test func draggingToTheNarrowestWidthKeepsThePlusClearOfForward() {
        let (window, root) = root()
        defer { window.close() }
        let container = root.sidebar
        container.handleDrag(.began)
        // Narrower than any minimum, but above the drag's hide threshold.
        container.handleDrag(.changed(SidebarContainerView.hideThreshold + 1 - container.model.width))
        settle(root)
        #expect(!container.model.isHidden)
        #expect(gapBeforePlus(root) >= Metrics.space2)
    }

    @Test func theMinimumIsDerivedFromTheTitlebarControls() {
        let (window, root) = root()
        defer { window.close() }
        let sidebarView = root.sidebar.sidebarView
        let controls = sidebarView.titlebarLeadingReserve + SidebarStyle.toolbarButtonSize + Metrics.space3
        #expect(root.sidebar.model.minimumWidth == max(Metrics.sidebarMinWidth, controls))
    }

    @Test func thePriorityBellWidensTheMinimumAndStaysClearOfForward() {
        let (window, root) = root()
        defer { window.close() }
        let container = root.sidebar
        let before = container.model.minimumWidth
        container.sidebarView.showPriority(SidebarPriorityPanel(entries: []))
        #expect(container.model.minimumWidth >= before + SidebarStyle.toolbarButtonSize)
        container.restore(width: 160, presentation: .shown)
        settle(root)
        let forward = root.toolbarBand.convert(root.toolbarBand.forwardButton.frame, to: root)
        let bell = container.sidebarView.convert(container.sidebarView.priorityButton.frame, to: root)
        #expect(bell.minX - forward.maxX >= Metrics.space2)
        container.sidebarView.showPriority(nil)
        #expect(container.model.minimumWidth == before)
    }

    @Test(.timeLimit(.minutes(1)))
    func anExistingTitlebarUpdatesItsTrafficLightReserveWhenTheTokenChanges() async throws {
        let store = TunableStore.shared
        let token = ChromeTunables.trafficLightInset
        store.register([token.descriptor])
        store.activate(file: nil)
        let saved = store.overrides[token.key]
        defer { store.set(token.key, saved) }
        store.set(token.key, .number(76))
        let (window, root) = root()
        defer { window.close() }
        let reserve = try #require(root.constraints.first {
            $0.firstItem === root.titlebar && $0.firstAttribute == .leading && $0.relation == .greaterThanOrEqual
        })
        let before = reserve.constant
        // NSLayoutConstraint exposes its update through KVO; the stream waits for that real
        // change and the deferred cleanup ends both the stream and its observation.
        let changes = AsyncStream<CGFloat>.makeStream()
        let observation = reserve.observe(\.constant, options: [.new]) { constraint, _ in
            changes.continuation.yield(constraint.constant)
        }
        defer { observation.invalidate(); changes.continuation.finish() }
        var constants = changes.stream.makeAsyncIterator()
        store.set(token.key, .number(104))
        let expected = Metrics.trafficLightInset
        while let value = await constants.next() { if value == expected { break } }
        #expect(reserve.constant == expected)
        #expect(reserve.constant > before)
    }

    /// The display is synthetic so the same assertions run on every fleet screen. The fractional
    /// resting frame exercises alignment without changing or repositioning AppKit's real buttons.
    final class ChromeGeometryWindow: NSWindow, TrafficLightsResting {
        var testScale: CGFloat = 1
        override var backingScaleFactor: CGFloat { testScale }
        var restingTrafficLights: CGRect? {
            CGRect(x: 8.2, y: frame.height - 22.4, width: 52.2, height: 14)
        }
    }

    @Test(arguments: [CGFloat(1), 2, 3], [DensityPreset.compact, .comfortable])
    func titlebarControlsShareTheDisplaysPixelGrid(scale: CGFloat, density: DensityPreset) throws {
        let design = DesignSettings.shared
        let saved = design.densityTokens
        defer { design.densityTokens = saved }
        design.densityTokens = density.tokens
        _ = NSApplication.shared
        let window = ChromeGeometryWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
                                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                         backing: .buffered, defer: false)
        window.testScale = scale
        let (_, root) = root(window: window)
        defer { window.close() }
        let badge = NSTextField(labelWithString: "Private")
        root.titlebarBadge = badge
        root.showsTitlebarBadge = true
        let indicator = NSView(frame: .zero)
        root.hostPressureIndicator = indicator
        for size in [CGSize(width: 701, height: 501), CGSize(width: 1439, height: 901)] {
            window.setContentSize(size)
            settle(root)
            let lights = try #require(WindowTitlebar.trafficLightsFrame(in: window))
            let center = root.convert(lights, from: nil).midY
            for view in [root.toolbarBand, badge, indicator] as [NSView] {
                let frame = view.frame
                for edge in [frame.minX, frame.maxX, frame.minY, frame.maxY] {
                    #expect(abs(edge * scale - (edge * scale).rounded()) < 0.0001,
                            "\(density)/\(scale)x: \(frame) has an edge between device pixels")
                }
                #expect(abs(frame.midY - center) * scale <= 0.5001,
                        "\(density)/\(scale)x: \(frame) left the traffic lights' center line")
            }
        }
    }
}
