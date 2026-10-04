public import CmuxNextDesign
public import CoreGraphics

/// Column and split defaults in cmux.json (plans/cmux-next/column-sizing.md):
/// `layout.splitSizing`, `layout.newColumnWidth`, `layout.stickyColumnEdge`,
/// `layout.stickyColumnMode`, `layout.frameOrientation`, `layout.minimumPaneWidth`,
/// `layout.minimumPaneHeight`, `layout.rows`. A missing key is the default with no
/// diagnostic; a bad value is the default plus a diagnostic.
public nonisolated enum ColumnLayoutSettings {
    public static let splitSizingPath = ["layout", "splitSizing"]
    public static let newColumnWidthPath = ["layout", "newColumnWidth"]
    public static let stickyEdgePath = ["layout", "stickyColumnEdge"]
    public static let stickyModePath = ["layout", "stickyColumnMode"]
    public static let frameOrientationPath = ["layout", "frameOrientation"]
    public static let minimumPaneWidthPath = ["layout", "minimumPaneWidth"]
    public static let minimumPaneHeightPath = ["layout", "minimumPaneHeight"]
    public static let rowsPath = ["layout", "rows"]

    public static let splitSizingFallback: SplitSizing = .even
    public static let newColumnWidthFallback: NewColumnWidthMode = .matchCurrent
    public static let stickyEdgeFallback: StickyDefaultEdge = .nearest
    public static let stickyModeFallback: StickyDefaultMode = .docked
    public static let frameOrientationFallback: FrameOrientation = .columnMajor
    /// `layout.rows` defaults on for dogfood (rows.md O1).
    public static let rowsFallback = true
    public static let minimumPaneWidthFallback: Double = 200
    public static let minimumPaneHeightFallback: Double = 64
    public static let minimumPaneWidthRange: ClosedRange<Double> = 80...800
    public static let minimumPaneHeightRange: ClosedRange<Double> = 32...600

    static func choice<T: RawRepresentable & CaseIterable>(_ root: JSONValue, _ path: [String], fallback: T,
                                                           diagnostics: inout [SettingsDiagnostic]) -> T where T.RawValue == String {
        guard let value = root.value(at: path) else { return fallback }
        guard let text = value.stringValue, let parsed = T(rawValue: text) else {
            let choices = T.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
            diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: path.joined(separator: "."), message: "expected one of \(choices)"))
            return fallback
        }
        return parsed
    }

    static func number(_ root: JSONValue, _ path: [String], fallback: Double, range: ClosedRange<Double>,
                       diagnostics: inout [SettingsDiagnostic]) -> Double {
        guard let value = root.value(at: path) else { return fallback }
        guard let number = value.doubleValue, range.contains(number) else {
            diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: path.joined(separator: "."),
                                                  message: "expected points from \(Int(range.lowerBound)) to \(Int(range.upperBound))"))
            return fallback
        }
        return number
    }

    /// `layout.newColumnWidth` also takes a number: a fixed share, which
    /// then wins over `layout.defaultColumnWidth`.
    static func newColumnWidth(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> (NewColumnWidthMode, Double?) {
        if let number = root.value(at: newColumnWidthPath)?.doubleValue {
            guard DefaultColumnWidthSetting.range.contains(number) else {
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: "layout.newColumnWidth",
                                                      message: "expected \"matchCurrent\", \"fitScreen\", \"fixed\" or a share from 0.1 to 1.0"))
                return (newColumnWidthFallback, nil)
            }
            return (.fixed, number)
        }
        return (choice(root, newColumnWidthPath, fallback: newColumnWidthFallback, diagnostics: &diagnostics), nil)
    }

    /// Parses every key into `snapshot`.
    static func parse(_ root: JSONValue, into snapshot: inout CmuxConfigSnapshot) {
        var diagnostics: [SettingsDiagnostic] = []
        snapshot.splitSizing = choice(root, splitSizingPath, fallback: splitSizingFallback, diagnostics: &diagnostics)
        let (mode, fixed) = newColumnWidth(root, diagnostics: &diagnostics)
        snapshot.newColumnWidth = mode
        if let fixed { snapshot.defaultColumnWidth = fixed }
        snapshot.stickyColumnEdge = choice(root, stickyEdgePath, fallback: stickyEdgeFallback, diagnostics: &diagnostics)
        // "floating" is the UI name of `overlay`; both are accepted.
        if root.value(at: stickyModePath)?.stringValue == "floating" {
            snapshot.stickyColumnMode = .overlay
        } else {
            snapshot.stickyColumnMode = choice(root, stickyModePath, fallback: stickyModeFallback, diagnostics: &diagnostics)
        }
        snapshot.frameOrientation = choice(root, frameOrientationPath, fallback: frameOrientationFallback, diagnostics: &diagnostics)
        let width = number(root, minimumPaneWidthPath, fallback: minimumPaneWidthFallback, range: minimumPaneWidthRange, diagnostics: &diagnostics)
        let height = number(root, minimumPaneHeightPath, fallback: minimumPaneHeightFallback, range: minimumPaneHeightRange,
                            diagnostics: &diagnostics)
        snapshot.minimumPaneContentSize = CGSize(width: width, height: height)
        if let value = root.value(at: rowsPath) {
            if let on = value.boolValue {
                snapshot.layoutRows = on
            } else {
                snapshot.layoutRows = rowsFallback
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: "layout.rows", message: "expected true or false"))
            }
        } else {
            snapshot.layoutRows = rowsFallback
        }
        snapshot.diagnostics += diagnostics
    }
}
