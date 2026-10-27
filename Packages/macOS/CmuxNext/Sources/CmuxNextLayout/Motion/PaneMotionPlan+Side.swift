import CmuxNextDesign
import CoreGraphics

nonisolated extension PaneMotionPlan {
    /// The container an item rests in: the strip or the view, and the row column and scroll area
    /// whose offsets move it.
    nonisolated struct Placement: Hashable, Sendable {
        var inStrip: Bool
        var rowColumn: ColumnID?
        var area: SplitID?
    }

    /// A divider handle's frame, axis and container, as `ScreenContentView.reconcile` places it.
    nonisolated struct Handle {
        var rect: CGRect
        var axis: SplitAxis
        var placement: Placement
    }

    /// One geometry with its containers where a camera puts them.
    nonisolated struct Side {
        let geometry: ScreenGeometry
        let camera: Camera
        /// The strip container's x in the view.
        let stripMinX: CGFloat

        init(geometry: ScreenGeometry, camera: Camera, stripMinX: CGFloat? = nil) {
            self.geometry = geometry
            self.camera = camera
            self.stripMinX = stripMinX ?? geometry.stripMinX
        }

        /// `next`'s containers where the change starts them: at the camera's `from` values
        /// (`PaneMotionPlan.camera`), or the strip at its rest where it comes or goes (a zoom).
        static func start(from previous: ScreenGeometry, camera fromCamera: Camera,
                          to next: ScreenGeometry, camera toCamera: Camera) -> Side {
            guard previous.isColumns != next.isColumns else {
                return Side(geometry: next, camera: fromCamera, stripMinX: previous.stripMinX)
            }
            var camera = fromCamera
            camera.stripOffset = toCamera.stripOffset
            return Side(geometry: next, camera: camera)
        }

        /// The view x of strip content x.
        var stripShift: CGFloat { stripMinX - camera.stripOffset }

        func placement(of pane: PaneID) -> Placement {
            Placement(inStrip: geometry.isColumns && !geometry.fixedPanes.contains(pane),
                      rowColumn: geometry.rowColumnOfPane[pane], area: geometry.scrollAreaOfPane[pane])
        }

        /// `rect`, resting in `out` on `side`, in `into`'s space on this side: where it showed. The
        /// shifts are subtracted before the rect moves, so the same container leaves it exact.
        func carry(_ rect: CGRect, from out: Placement, on side: Side, to into: Placement) -> CGRect {
            let shown = side.shift(out), here = shift(into)
            return rect.offsetBy(dx: shown.dx - here.dx, dy: shown.dy - here.dy)
        }

        /// How far `placement`'s container moves its content in the view.
        private func shift(_ placement: Placement) -> CGVector {
            let strip = placement.inStrip ? stripShift : 0
            let area = placement.area.map { camera.areaOffsets[$0] ?? 0 } ?? 0
            let row = placement.rowColumn.map { camera.rowOffsets[$0] ?? 0 } ?? 0
            return CGVector(dx: strip - area, dy: -row)
        }

        /// Every divider handle, as `ScreenContentView.reconcile` places them.
        func dividers(includesRowEdges: Bool) -> [DividerKey: Handle] {
            var result: [DividerKey: Handle] = [:]
            result.reserveCapacity(geometry.dividers.count + geometry.columnEdges.count + (includesRowEdges ? geometry.rowEdges.count : 0))
            for divider in geometry.dividers {
                let placement = Placement(inStrip: geometry.isColumns && !geometry.fixedSplits.contains(divider.id),
                                          rowColumn: geometry.rowColumnOfSplit[divider.id], area: geometry.scrollAreaOfSplit[divider.id])
                result[.split(divider.id)] = Handle(rect: divider.hitFrame, axis: divider.axis, placement: placement)
            }
            for edge in geometry.columnEdges {
                let placement = Placement(inStrip: inStrip(column: edge.column))
                result[.columnEdge(edge.column)] = Handle(rect: edge.hitFrame, axis: edge.axis, placement: placement)
            }
            if includesRowEdges {
                for edge in geometry.rowEdges {
                    let placement = Placement(inStrip: inStrip(column: edge.column), rowColumn: edge.column)
                    result[.rowEdge(edge.column, edge.upper)] = Handle(rect: edge.hitFrame, axis: .vertical, placement: placement)
                }
            }
            return result
        }

        private func inStrip(column: ColumnID) -> Bool {
            geometry.isColumns && !geometry.dock.contains { $0.column == column }
        }
    }
}
