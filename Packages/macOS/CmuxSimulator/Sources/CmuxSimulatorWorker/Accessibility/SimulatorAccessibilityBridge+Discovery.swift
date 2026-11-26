import AppKit
import CmuxSimulator
import Foundation
import ObjectiveC.runtime

// Adapted from serve-sim's AccessibilityBridge.swift at commit
// af681b8c3b0453f31dcb8e98a3389f23b7cfc6b0 under Apache License 2.0.
// Modified by cmux to distribute a capped grid across the full display, emit
// typed nodes, and deduplicate frames inside the isolated worker.

extension SimulatorAccessibilityBridge {
    /// Discovers controls hidden by scroll views and custom accessibility
    /// containers by hit-testing an evenly distributed, bounded screen grid.
    func discoverAccessibilityElements(
        token: String,
        bounds: NSRect,
        remaining: inout Int,
        visited: inout Set<ObjectIdentifier>,
        coverage: inout SimulatorAccessibilityCoverage,
        traversalTruncated: inout Bool
    ) -> [SimulatorAccessibilityNode] {
        guard remaining > 0, bounds.isFiniteAndVisible,
              let translator = try? requireTranslator()
        else { return [] }
        let pointSelector = NSSelectorFromString(
            "objectAtPoint:displayId:bridgeDelegateToken:"
        )
        let elementSelector = NSSelectorFromString("macPlatformElementFromTranslation:")
        guard translator.responds(to: pointSelector),
              translator.responds(to: elementSelector),
              let pointImplementation = class_getMethodImplementation(
                  type(of: translator), pointSelector
              ),
              let elementImplementation = class_getMethodImplementation(
                  type(of: translator), elementSelector
              )
        else { return [] }

        typealias PointFunction = @convention(c) (
            AnyObject, Selector, CGPoint, UInt32, NSString
        ) -> AnyObject?
        typealias ElementFunction = @convention(c) (
            AnyObject, Selector, AnyObject
        ) -> AnyObject?
        let objectAtPoint = unsafeBitCast(pointImplementation, to: PointFunction.self)
        let platformElement = unsafeBitCast(elementImplementation, to: ElementFunction.self)

        var result: [SimulatorAccessibilityNode] = []
        let points = accessibilityGrid.points(in: bounds)
        for (index, point) in points.enumerated() where remaining > 0 {
            if coverage.contains(point) { continue }
            guard let translation = objectAtPoint(
                translator, pointSelector, point, 0, token as NSString
            ) as? NSObject else { continue }
            stampToken(on: translation, token: token)
            guard let element = platformElement(
                translator, elementSelector, translation
            ) as? NSObject else { continue }
            stampNestedTranslation(on: element, token: token)

            let frame = (element as? NSAccessibilityElement)?.accessibilityFrame() ?? .zero
            guard frame.isFiniteAndVisible, !coverage.contains(frame) else { continue }
            if frame.approximatelyMatches(bounds) {
                coverage.insertContainer(frame)
                continue
            }
            if let node = serialize(
                element,
                path: "grid.\(index)",
                token: token,
                depth: 0,
                remaining: &remaining,
                visited: &visited,
                coverage: &coverage,
                traversalTruncated: &traversalTruncated
            ) {
                result.append(node)
            }
        }
        return result
    }
}

struct SimulatorAccessibilityGrid {
    let preferredStep: CGFloat
    let maximumPointCount: Int

    init(preferredStep: CGFloat = 32, maximumPointCount: Int = 768) {
        self.preferredStep = preferredStep
        self.maximumPointCount = maximumPointCount
    }

    func points(in bounds: NSRect) -> [CGPoint] {
        guard bounds.isFiniteAndVisible else { return [] }
        let preferredColumns = max(1, Int(ceil(bounds.width / preferredStep)))
        let preferredRows = max(1, Int(ceil(bounds.height / preferredStep)))
        let preferredCount = preferredColumns * preferredRows
        let scale = preferredCount > maximumPointCount
            ? sqrt(CGFloat(preferredCount) / CGFloat(maximumPointCount))
            : 1
        var columns = max(1, Int(floor(CGFloat(preferredColumns) / scale)))
        var rows = max(1, Int(floor(CGFloat(preferredRows) / scale)))
        while columns * rows > maximumPointCount {
            if columns >= rows { columns -= 1 } else { rows -= 1 }
        }

        let horizontalStep = bounds.width / CGFloat(columns)
        let verticalStep = bounds.height / CGFloat(rows)
        return (0..<rows).flatMap { row in
            (0..<columns).map { column in
                CGPoint(
                    x: bounds.minX + (CGFloat(column) + 0.5) * horizontalStep,
                    y: bounds.minY + (CGFloat(row) + 0.5) * verticalStep
                )
            }
        }
    }
}

extension NSRect {
    var isFiniteAndVisible: Bool {
        origin.x.isFinite && origin.y.isFinite && width.isFinite && height.isFinite
            && width > 0 && height > 0
    }

    func approximatelyMatches(_ other: NSRect) -> Bool {
        abs(width - other.width) < 1 && abs(height - other.height) < 1
            && abs(minX - other.minX) < 1 && abs(minY - other.minY) < 1
    }
}
