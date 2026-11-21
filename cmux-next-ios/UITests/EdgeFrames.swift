import XCTest

/// Row frames from one accessibility snapshot, for the shift-bar checks: a row being read moves
/// at most `shiftBar` points (acceptance SB). Also in the ios-live-coalesce branch's UI tests.
@MainActor
enum RowFrames {
    static let shiftBar: CGFloat = 0.5

    /// Every element under `root` whose identifier starts with `prefix` and that is on screen
    /// inside `root`'s frame, by identifier (one snapshot: the frames are of one moment).
    static func read(_ root: XCUIElement, prefix: String) -> [String: CGRect] {
        read(root) { $0.identifier.hasPrefix(prefix) ? $0.identifier : nil }
    }

    /// Every element under `root` that `key` names, on screen inside `root`'s frame, by that name.
    static func read(_ root: XCUIElement, key: (XCUIElementSnapshot) -> String?) -> [String: CGRect] {
        guard let snapshot = try? root.snapshot() else { return [:] }
        let bounds = snapshot.frame
        var out: [String: CGRect] = [:]
        func walk(_ node: XCUIElementSnapshot) {
            if let name = key(node), node.frame.height > 0, node.frame.intersects(bounds), out[name] == nil {
                out[name] = node.frame
            }
            for child in node.children { walk(child) }
        }
        walk(snapshot)
        return out
    }

    /// The frames once two reads a poll apart agree (scrolling and row animations ended).
    static func settled(_ root: XCUIElement, prefix: String, timeout: TimeInterval = 10) -> [String: CGRect] {
        settled(root, timeout: timeout) { $0.identifier.hasPrefix(prefix) ? $0.identifier : nil }
    }

    static func settled(_ root: XCUIElement, timeout: TimeInterval = 10, key: @escaping (XCUIElementSnapshot) -> String?) -> [String: CGRect] {
        var last: [String: CGRect]?
        var agreed: [String: CGRect] = [:]
        let still = NSPredicate { _, _ in
            let now = read(root, key: key)
            defer { last = now }
            guard let last, !now.isEmpty, last == now else { return false }
            agreed = now
            return true
        }
        _ = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: still, object: nil)], timeout: timeout)
        return agreed.isEmpty ? read(root, key: key) : agreed
    }

    /// The row whose middle is nearest `root`'s middle: the one being read.
    static func reader(_ frames: [String: CGRect], in root: XCUIElement) -> String? {
        let mid = root.frame.midY
        return frames.min { abs($0.value.midY - mid) < abs($1.value.midY - mid) }?.key
    }

    /// Scrolls `root` with slow swipes until `row` sits in the middle band of the screen (above
    /// the tab bar, with rows below it to measure).
    static func bring(_ row: XCUIElement, toMiddleOf root: XCUIElement, attempts: Int = 30) {
        for _ in 0..<attempts {
            let band = (root.frame.minY + root.frame.height * 0.3)...(root.frame.minY + root.frame.height * 0.55)
            if row.exists, band.contains(row.frame.midY) { return }
            if row.exists, row.frame.midY < band.lowerBound {
                drag(root, by: min(row.frame.height * 2, band.lowerBound - row.frame.midY + 40))
            } else if row.exists, row.frame.midY < root.frame.maxY {
                drag(root, by: -(row.frame.midY - band.upperBound + 40))
            } else {
                drag(root, by: -root.frame.height * 0.4)
            }
        }
    }

    /// A slow drag of `points` (positive: content moves down), held at the end so it does not fling.
    static func drag(_ root: XCUIElement, by points: CGFloat) {
        let height = root.frame.height
        let start = root.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: points > 0 ? 0.3 : 0.7))
        let end = start.withOffset(CGVector(dx: 0, dy: max(-height * 0.6, min(height * 0.6, points))))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.3)
    }

    /// Asserts the removed row's neighbours: rows above it stay (≤ SB), rows below it move up by
    /// exactly the removed row's pitch (≤ SB), so the next row takes its place.
    static func expectGapClosed(before: [String: CGRect], after: [String: CGRect], removed id: String,
                                file: StaticString = #filePath, line: UInt = #line) -> String {
        guard let gone = before[id] else {
            XCTFail("the removed row was not measured", file: file, line: line)
            return ""
        }
        let below = before.filter { $0.key != id && $0.value.minY > gone.minY }
        let next = below.min { $0.value.minY < $1.value.minY }
        let pitch = next.map { $0.value.minY - gone.minY } ?? gone.height
        var report: [String] = ["removed \(id) at y=\(gone.minY) h=\(gone.height) pitch=\(pitch)"]
        var compared = 0
        for (key, old) in before where key != id {
            guard let new = after[key] else { continue }
            let shift = new.minY - old.minY
            let expected: CGFloat = old.minY < gone.minY ? 0 : -pitch
            report.append("\(key) \(old.minY)->\(new.minY) shift=\(shift) expected=\(expected)")
            compared += 1
            XCTAssertLessThanOrEqual(abs(shift - expected), shiftBar,
                                     "\(key) moved \(shift) pt, expected \(expected) (removed \(id))", file: file, line: line)
        }
        XCTAssertGreaterThan(compared, 2, "too few rows measured on both sides", file: file, line: line)
        if let next, let new = after[next.key] {
            XCTAssertLessThanOrEqual(abs(new.minY - gone.minY), shiftBar,
                                     "\(next.key) takes the removed row's place: \(new.minY) vs \(gone.minY)", file: file, line: line)
        }
        return report.joined(separator: "\n")
    }
}

extension XCTestCase {
    @MainActor func edgeShot(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor func edgeNote(_ text: String, _ name: String) {
        let note = XCTAttachment(string: text)
        note.name = name
        note.lifetime = .keepAlways
        add(note)
        print("EDGE \(name):\n\(text)")
    }
}

extension RowFrames {
    /// A static text's label as its key (transcript rows have no identifiers; their text is unique).
    static func text(_ node: XCUIElementSnapshot) -> String? {
        node.elementType == .staticText && !node.label.isEmpty ? node.label : nil
    }

    /// An Event Inspector row by its record's seq ("seq 12" in its label).
    static func inspectorSeq(_ node: XCUIElementSnapshot) -> String? {
        guard node.identifier == "chat.inspector.row", let range = node.label.range(of: #"seq \d+"#, options: .regularExpression) else { return nil }
        return String(node.label[range])
    }
}
