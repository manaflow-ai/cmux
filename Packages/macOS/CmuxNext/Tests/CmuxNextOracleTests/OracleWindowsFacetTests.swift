#if DEBUG || CMUX_BENCH_HOOKS
import CmuxNextOracle
import Testing

/// The windows facet: windows front to back, key and main, and each frame as fractions of its
/// screen at 2 dp, never points. Run: `swift test --filter OracleWindowsFacetTests`.
@MainActor
struct OracleWindowsFacetTests {
    typealias Facet = OracleWindowsFacet

    /// A 1440 x 900 display with a 25 pt menu bar at the top and no Dock, and a 1920 x 1080 one to its right.
    private let laptop = Facet.Screen(frame: Facet.Rect(x: 0, y: 0, width: 1440, height: 900),
                                      visibleFrame: Facet.Rect(x: 0, y: 0, width: 1440, height: 875))
    private let external = Facet.Screen(frame: Facet.Rect(x: 1440, y: 0, width: 1920, height: 1080),
                                        visibleFrame: Facet.Rect(x: 1440, y: 0, width: 1920, height: 1055))

    private func window(_ id: String, _ frame: Facet.Rect, screen: Int? = 0, fullscreen: Bool = false,
                        miniaturized: Bool = false, visible: Bool = true) -> Facet.Window {
        Facet.Window(id: id, frame: frame, screen: screen, fullscreen: fullscreen, miniaturized: miniaturized, visible: visible)
    }

    private func value(_ reading: Facet.Reading) throws -> OracleValue {
        let facet = Facet { reading }
        #expect(facet.facet == .windows)
        return try #require(try OracleFacets([facet]).beginCapture([.windows]).completed?["windows"])
    }

    /// The frame is fractions of the screen's visible frame, measured from its top left, at 2 dp.
    @Test func framesAreScreenFractionsFromTheTopLeft() throws {
        // 144 pt from the left, its top 337.5 pt below the visible frame's top, half the visible width and height.
        let reading = Facet.Reading(screens: [laptop], windows: [window("win_a", Facet.Rect(x: 144, y: 100, width: 720, height: 437.5))],
                                    key: "win_a", main: "win_a")
        let expected: OracleValue = [
            "count": 1, "order": ["win_a"], "key": "win_a", "main": "win_a",
            "list": [[
                "id": "win_a", "fullscreen": false, "miniaturized": false, "visible": true, "screen": 0,
                "frame": ["x": 0.1, "y": 0.39, "width": 0.5, "height": 0.5],
            ]],
        ]
        #expect(try value(reading) == expected)
    }

    /// The same placement on a bigger display gives the same fractions: no points reach the facet.
    @Test func theSamePlacementOnAnotherDisplayGivesTheSameFractions() throws {
        func frame(on screen: Facet.Screen) throws -> OracleValue? {
            let visible = screen.visibleFrame
            let rect = Facet.Rect(x: visible.x + visible.width / 4, y: visible.y + visible.height / 4,
                                  width: visible.width / 2, height: visible.height / 2)
            let reading = Facet.Reading(screens: [screen], windows: [window("win_a", rect)], key: nil, main: nil)
            guard case .array(let list)? = try value(reading)["list"] else { return nil }
            return list.first?["frame"]
        }
        let small = try frame(on: laptop)
        #expect(small == ["x": 0.25, "y": 0.25, "width": 0.5, "height": 0.5])
        #expect(try frame(on: external) == small)
    }

    /// A full-screen window measures against the whole screen, so it is the unit square on any display.
    @Test func aFullScreenWindowIsTheWholeScreen() throws {
        let reading = Facet.Reading(screens: [laptop, external],
                                    windows: [window("win_a", external.frame, screen: 1, fullscreen: true)], key: "win_a", main: "win_a")
        guard case .array(let list)? = try value(reading)["list"] else {
            Issue.record("no list")
            return
        }
        #expect(list.first?["screen"] == 1)
        #expect(list.first?["fullscreen"] == true)
        #expect(list.first?["frame"] == ["x": 0, "y": 0, "width": 1, "height": 1])
    }

    /// Order is the reading's front-to-back order; key and main are independent, and either may be no window.
    @Test func orderKeyAndMain() throws {
        let reading = Facet.Reading(screens: [laptop], windows: [
            window("win_b", Facet.Rect(x: 0, y: 0, width: 720, height: 875)),
            window("win_a", Facet.Rect(x: 720, y: 0, width: 720, height: 875), miniaturized: true, visible: false),
        ], key: nil, main: "win_b")
        let result = try value(reading)
        #expect(result["count"] == 2)
        #expect(result["order"] == ["win_b", "win_a"])
        #expect(result["key"] == OracleValue.null)
        #expect(result["main"] == "win_b")
        guard case .array(let list)? = result["list"] else {
            Issue.record("no list")
            return
        }
        #expect(list.map { $0["miniaturized"] ?? .null } == [false, true])
        #expect(list.map { $0["visible"] ?? .null } == [true, false])
    }

    /// No window: an empty list and no key or main, not an error.
    @Test func noWindowIsAnEmptyList() throws {
        #expect(try value(Facet.Reading(screens: [laptop], windows: [], key: nil, main: nil))
            == ["count": 0, "order": [], "key": nil, "main": nil, "list": []])
    }

    /// A window AppKit puts on no screen is measured on the screen that holds most of it; one that overlaps no
    /// screen has none (never screen 0 by default).
    @Test func aWindowWithNoScreenUsesTheScreenThatHoldsMostOfIt() {
        let reading = Facet.Reading(screens: [laptop, external], windows: [], key: nil, main: nil)
        #expect(reading.screenIndex(of: window("w", Facet.Rect(x: 1300, y: 0, width: 600, height: 400), screen: nil)) == 1)
        #expect(reading.screenIndex(of: window("w", Facet.Rect(x: -5000, y: -5000, width: 10, height: 10), screen: nil)) == nil)
        #expect(reading.screenIndex(of: window("w", Facet.Rect(x: 0, y: 0, width: 10, height: 10), screen: 7)) == 0)
    }

    /// A window with no screen to measure against fails the snapshot instead of recording a made-up frame:
    /// with no screen at all, and off every screen while there are screens.
    @Test func aWindowOnNoScreenFails() {
        let offEveryScreen = window("win_a", Facet.Rect(x: -5000, y: -5000, width: 10, height: 10), screen: nil)
        for screens in [[], [laptop, external]] as [[Facet.Screen]] {
            let reading = Facet.Reading(screens: screens, windows: [offEveryScreen], key: nil, main: nil)
            let facets = OracleFacets([Facet { reading }])
            #expect(throws: OracleSnapshotError.self) {
                try facets.beginCapture([.windows])
            }
        }
    }

    @Test func roundingHasNoNegativeZero() {
        #expect(Facet.rounded(-0.001) == 0)
        #expect(Facet.rounded(-0.001).sign == .plus)
        #expect(Facet.rounded(0.333) == 0.33)
        #expect(Facet.rounded(0.126) == 0.13)
    }
}
#endif
