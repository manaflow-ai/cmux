public import CmuxNextDesign
public import CoreGraphics

/// Column and split defaults in cmux.json (plans/cmux-next/column-sizing.md):
/// `layout.splitSizing`, `layout.newColumnWidth`, `layout.dockColumnEdge`,
/// `layout.dockColumnMode`, `layout.frameOrientation`, `layout.minimumPaneWidth`,
/// `layout.minimumPaneHeight`, `layout.rows`, `layout.focusFollowsMouse`, `layout.scrollAreas`,
/// `layout.scrollModifier`, `layout.pagesHandleCommandScroll`. A missing key is the default with no
/// diagnostic; a bad value is the default plus a diagnostic.
public nonisolated enum ColumnLayoutSettings {
    /// R87: the keys nightly-next builds wrote before the dock rename, read
    /// for one release when the dock key is absent. Remove after it.
    static let legacyDockEdgePath = ["layout", "stickyColumnEdge"]
    static let legacyDockModePath = ["layout", "stickyColumnMode"]

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
                return (newColumnWidthDefault, nil)
            }
            return (.fixed, number)
        }
        return (choice(root, newColumnWidthPath, fallback: newColumnWidthDefault, diagnostics: &diagnostics), nil)
    }

    /// `path`, or `legacy` when only the old key is set (R87).
    static func path(_ root: JSONValue, _ path: [String], legacy: [String]) -> [String] {
        root.value(at: path) == nil && root.value(at: legacy) != nil ? legacy : path
    }

    /// Parses every key into `snapshot`.
    static func parse(_ root: JSONValue, into snapshot: inout CmuxConfigSnapshot) {
        var diagnostics: [SettingsDiagnostic] = []
        snapshot.splitSizing = choice(root, splitSizingPath, fallback: splitSizingDefault, diagnostics: &diagnostics)
        let (mode, fixed) = newColumnWidth(root, diagnostics: &diagnostics)
        snapshot.newColumnWidth = mode
        if let fixed { snapshot.defaultColumnWidth = fixed }
        let edgePath = path(root, dockEdgePath, legacy: legacyDockEdgePath)
        snapshot.dockColumnEdge = choice(root, edgePath, fallback: dockEdgeDefault, diagnostics: &diagnostics)
        // "floating" is the UI name of `overlay`; both are accepted.
        let modePath = path(root, dockModePath, legacy: legacyDockModePath)
        if root.value(at: modePath)?.stringValue == "floating" {
            snapshot.dockColumnMode = .overlay
        } else {
            snapshot.dockColumnMode = choice(root, modePath, fallback: dockModeDefault, diagnostics: &diagnostics)
        }
        snapshot.frameOrientation = choice(root, frameOrientationPath, fallback: frameOrientationDefault, diagnostics: &diagnostics)
        snapshot.layoutScrollModifier = choice(root, scrollModifierPath, fallback: scrollModifierDefault, diagnostics: &diagnostics)
        let width = number(root, minimumPaneWidthPath, fallback: minimumPaneWidthDefault, range: minimumPaneWidthRange, diagnostics: &diagnostics)
        let height = number(root, minimumPaneHeightPath, fallback: minimumPaneHeightDefault, range: minimumPaneHeightRange,
                            diagnostics: &diagnostics)
        snapshot.minimumPaneContentSize = CGSize(width: width, height: height)
        if let value = root.value(at: rowsPath) {
            if let on = value.boolValue {
                snapshot.layoutRows = on
            } else {
                snapshot.layoutRows = rowsDefault
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: "layout.rows", message: "expected true or false"))
            }
        } else {
            snapshot.layoutRows = rowsDefault
        }
        if let value = root.value(at: focusFollowsMousePath) {
            if let on = value.boolValue {
                snapshot.focusFollowsMouse = on
            } else {
                snapshot.focusFollowsMouse = focusFollowsMouseDefault
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: "layout.focusFollowsMouse", message: "expected true or false"))
            }
        } else {
            snapshot.focusFollowsMouse = focusFollowsMouseDefault
        }
        if let value = root.value(at: scrollAreasPath) {
            if let on = value.boolValue {
                snapshot.layoutScrollAreas = on
            } else {
                snapshot.layoutScrollAreas = scrollAreasDefault
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: "layout.scrollAreas", message: "expected true or false"))
            }
        } else {
            snapshot.layoutScrollAreas = scrollAreasDefault
        }
        if let value = root.value(at: pagesHandleCommandScrollPath) {
            if let on = value.boolValue {
                snapshot.pagesHandleCommandScroll = on
            } else {
                snapshot.pagesHandleCommandScroll = pagesHandleCommandScrollDefault
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: "layout.pagesHandleCommandScroll",
                                                      message: "expected true or false"))
            }
        } else {
            snapshot.pagesHandleCommandScroll = pagesHandleCommandScrollDefault
        }
        snapshot.diagnostics += diagnostics
    }
}
