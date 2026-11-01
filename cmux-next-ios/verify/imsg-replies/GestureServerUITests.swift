// Rig only (verify/imsg-replies, copied into UITests by the rig's build): a
// gesture server for side-by-side runs against Messages. axe's drags reach
// neither app's pan recognizers on the iOS 27 simulator, so real swipes come
// from XCUITest here. It attaches to the already running app named by each
// command (Messages launched with ReplyOn.dylib keeps its injected state).
//
// Commands, one per file `<dir>/<n>.cmd` (dir from GESTURE_DIR), in points:
//   drag BUNDLE x0 y0 x1 y1 PRESS VELOCITY HOLD   press, drag at VELOCITY pt/s, hold, lift
//   tap BUNDLE x y
//   press BUNDLE x y SECONDS
//   type BUNDLE text...                  types into the focused field (XCUITest, slow in Messages)
//   keys BUNDLE text...                  taps software-keyboard keys (letters, spaces; a capital
//                                        not at the start taps shift first); iPhone 17 Pro Max
//   stop
// The server writes `<n>.done` after each one.
import ObjectiveC
import XCTest

final class GestureServerUITests: XCTestCase {
    func testServe() throws {
        // Chief's live transcript never idles; gestures must not wait for it.
        Self.skipQuiescence()
        let dir = ProcessInfo.processInfo.environment["GESTURE_DIR"] ?? "/tmp/imsgreply-gestures"
        let fm = FileManager.default
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var apps: [String: XCUIApplication] = [:]
        var next = 1
        while true {
            let path = "\(dir)/\(next).cmd"
            guard let line = try? String(contentsOfFile: path, encoding: .utf8) else {
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
                continue
            }
            let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
            if parts.first == "stop" { return }
            guard parts.count >= 2 else { next += 1; continue }
            let app = apps[parts[1]] ?? XCUIApplication(bundleIdentifier: parts[1])
            apps[parts[1]] = app
            let origin = app.coordinate(withNormalizedOffset: .zero)
            func point(_ x: String, _ y: String) -> XCUICoordinate {
                origin.withOffset(CGVector(dx: Double(x) ?? 0, dy: Double(y) ?? 0))
            }
            switch parts[0] {
            case "drag" where parts.count >= 9:
                point(parts[2], parts[3]).press(
                    forDuration: Double(parts[6]) ?? 0.05,
                    thenDragTo: point(parts[4], parts[5]),
                    withVelocity: XCUIGestureVelocity(Double(parts[7]) ?? 600),
                    thenHoldForDuration: Double(parts[8]) ?? 0
                )
            case "tap" where parts.count >= 4:
                point(parts[2], parts[3]).tap()
            case "type" where parts.count >= 3:
                app.typeText(parts[2...].joined(separator: " "))
            case "keys" where parts.count >= 3:
                Self.tapKeys(parts[2...].joined(separator: " "), at: point)
            case "press" where parts.count >= 5:
                point(parts[2], parts[3]).press(forDuration: Double(parts[4]) ?? 1)
            default:
                break
            }
            try? "ok".write(toFile: "\(dir)/\(next).done", atomically: true, encoding: .utf8)
            next += 1
        }
    }
}

extension GestureServerUITests {
    /// English QWERTY on an iPhone 17 Pro Max (440 pt wide), in points.
    static func keyPoint(_ key: Character) -> (Double, Double)? {
        let rows: [(String, Double, Double, Double)] = [
            ("qwertyuiop", 25, 43.2, 682), ("asdfghjkl", 46, 43.3, 739), ("zxcvbnm", 89, 43.4, 795),
        ]
        for (letters, x0, step, y) in rows {
            if let i = letters.firstIndex(of: key) { return (x0 + Double(letters.distance(from: letters.startIndex, to: i)) * step, y) }
        }
        return key == " " ? (220, 851) : nil
    }

    static func tapKeys(_ text: String, at point: (String, String) -> XCUICoordinate) {
        for (index, character) in text.enumerated() {
            let lower = Character(character.lowercased())
            guard let (x, y) = keyPoint(lower) else { continue }
            // Sentence start is auto-capitalized; any other capital needs shift.
            if character.isUppercase, index > 0 { point("32", "795").tap() }
            point(String(x), String(y)).tap()
        }
    }

    /// XCUIApplicationProcess waits for the app to idle before and after
    /// every synthesized event; the rig's gestures must run on time instead.
    static func skipQuiescence() {
        guard let cls = NSClassFromString("XCUIApplicationProcess") else { return }
        for name in ["waitForQuiescenceIncludingAnimationsIdle:", "waitForQuiescenceIncludingAnimationsIdle:isPreEvent:"] {
            let selector = NSSelectorFromString(name)
            guard let method = class_getInstanceMethod(cls, selector) else { continue }
            let block: @convention(block) (AnyObject, Bool, Bool) -> Void = { _, _, _ in }
            method_setImplementation(method, imp_implementationWithBlock(block))
        }
    }
}
