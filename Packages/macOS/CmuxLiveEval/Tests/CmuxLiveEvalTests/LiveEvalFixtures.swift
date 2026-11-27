import CmuxSwiftRender
import Foundation
@testable import CmuxLiveEval

/// Shared fixtures for the live-eval spike tests.
enum LiveEvalFixtures {
    /// The spike's ~40-line test program: counter Button + Text, TextField
    /// bound to `$text` + echoing Text, and a 3-row ForEach with per-row
    /// Toggle plus a shuffle Button.
    static let source = """
    @State var count = 0
    @State var text = ""
    @State var rows = [
        ["id": "a", "label": "Alpha", "isOn": false],
        ["id": "b", "label": "Beta", "isOn": true],
        ["id": "c", "label": "Gamma", "isOn": false],
    ]

    VStack(spacing: 8) {
        Button("Increment") {
            count += 1
        }
        Text("Count: \\(count)")
        Divider()
        TextField("Type here", text: $text)
        Text("Echo: \\(text)")
        Divider()
        ForEach($rows, id: \\.id) { $row in
            Toggle(row.label, isOn: $row.isOn)
        }
        Button("Shuffle") {
            rows.shuffle()
        }
        Spacer()
    }
    """

    /// A realistic-sidebar-sized program: several sections of mixed statements
    /// with row loops, used by the benchmark's full-tree re-eval measurement.
    static func sidebarSizedSource(sections: Int, rowsPerSection: Int) -> String {
        var source = "@State var query = \"\"\n@State var count = 0\n"
        for section in 0..<sections {
            let rows = (0..<rowsPerSection)
                .map { "[\"id\": \"s\(section)r\($0)\", \"label\": \"Row \($0)\", \"isOn\": false]" }
                .joined(separator: ", ")
            source += "@State var rows\(section) = [\(rows)]\n"
        }
        source += "VStack(spacing: 4) {\n"
        source += "    TextField(\"Search\", text: $query)\n"
        source += "    Text(\"Echo: \\(query)\")\n"
        for section in 0..<sections {
            source += """
                Text("Section \(section) (\\(rows\(section).count))")
                Divider()
                ForEach($rows\(section), id: \\.id) { $row in
                    HStack {
                        Text(row.label)
                        Spacer()
                        Toggle(row.label, isOn: $row.isOn)
                    }
                }

            """
        }
        source += "}\n"
        return source
    }
}

/// Deterministic RNG so interpreted `.shuffle()` permutations are stable in
/// tests (SplitMix64).
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// A mutable flag observable from a Sendable onChange closure.
final class ChangeFlag: @unchecked Sendable {
    private(set) var fired = false

    func mark() {
        fired = true
    }
}

/// Collects engine evaluation labels across SwiftUI update passes.
final class EvalRecorder: @unchecked Sendable {
    private(set) var labels: [String] = []

    func append(_ label: String) {
        labels.append(label)
    }

    func clear() {
        labels.removeAll()
    }
}
