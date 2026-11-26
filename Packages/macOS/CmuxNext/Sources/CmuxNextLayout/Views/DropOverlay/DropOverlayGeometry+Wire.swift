import CoreGraphics

// The JSON of the `drop_overlay_*` ops (cmux-layout-reducer-ffi `tab_drag_rules.rs`, the shapes of
// cmux-layout-reducer `drop_overlay_geometry`). Shapes only: nothing here decides.
nonisolated extension DropOverlayGeometry {
    enum Wire {
        struct Rect: Codable {
            var x: Double
            var y: Double
            var width: Double
            var height: Double

            init(_ rect: CGRect) {
                x = Double(rect.minX)
                y = Double(rect.minY)
                width = Double(rect.width)
                height = Double(rect.height)
            }

            var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
        }

        struct Point: Encodable {
            var x: Double
            var y: Double
        }

        struct SplitPreviewRequest: Encodable {
            var region: Rect
            var zone: String
            var gap: Double
        }

        struct SplitPreviewReply: Decodable {
            var incoming: Rect
            var existing: Rect?
        }

        struct InsertionLineRequest: Encodable {
            var region: Rect
            var zone: String
            var width: Double
            var length: Double
        }

        struct ZoneRequest: Encodable {
            var zone: String
        }

        struct EdgesReply: Decodable {
            var edges: [String]
        }

        struct BandRequest: Encodable {
            var rect: Rect
            var edge: String
            var depth: Double
        }

        struct InsetCardRequest: Encodable {
            var target: Rect
            var fraction: Double
            var maxWidth: Double
            var height: Double

            enum CodingKeys: String, CodingKey {
                case target
                case fraction
                case maxWidth = "max_width"
                case height
            }
        }

        struct TabPillRequest: Encodable {
            var target: Rect
            var width: Double
            var height: Double
            var inset: Double
        }

        struct MorphStartRequest: Encodable {
            var pointer: Point
            var width: Double
        }

        struct RectReply: Decodable {
            var rect: Rect
        }

        static func edge(_ edge: CGRectEdge) -> String {
            switch edge {
            case .minXEdge: "min_x"
            case .maxXEdge: "max_x"
            case .minYEdge: "min_y"
            case .maxYEdge: "max_y"
            @unknown default: "min_x"
            }
        }

        static func edge(named name: String) -> CGRectEdge? {
            switch name {
            case "min_x": .minXEdge
            case "max_x": .maxXEdge
            case "min_y": .minYEdge
            case "max_y": .maxYEdge
            default: nil
            }
        }

        /// One rect op; `.zero` (nothing drawn) when the reducer does not answer.
        static func rect<Request: Encodable>(_ operation: String, _ request: Request) -> CGRect {
            LayoutReducerJSON().call(operation, request, as: RectReply.self)?.rect.cgRect ?? .zero
        }
    }
}
