import CoreGraphics
import Foundation

// The JSON of the `sidebar_geometry_*` ops (cmux-layout-reducer-ffi `sidebar_geometry.rs`, the shapes of
// cmux-layout-reducer `sidebar_drop_geometry`). Shapes only: nothing here decides.
/// A reply that says Rust no longer keeps the geometry (`{"gone": true}`): the slots go again.
nonisolated protocol SidebarGeometryReply {
    var gone: Bool? { get }
}

nonisolated extension SidebarDragGeometry {
    enum Wire {
        struct Frame: Encodable {
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
        }

        struct Slot: Encodable {
            var key: String
            var item: String?
            var section: String
            var parent: String?
            var frame: Frame
            var kind: String
            var collapsed: Bool

            init(_ slot: SidebarDragGeometry.Slot) {
                key = slot.key
                item = slot.item
                section = slot.section
                parent = slot.parent
                frame = Frame(slot.frame)
                kind = switch slot.kind {
                case .row: "row"
                case .group: "group"
                case .tile: "tile"
                case .section: "section"
                case .emptyGroup: "empty_group"
                }
                collapsed = slot.collapsed
            }
        }

        struct Acceptance: Encodable {
            var before: Bool
            var into: Bool
            var after: Bool
            var refusal: String?

            init(_ acceptance: SidebarDocAcceptance) {
                before = acceptance.before
                into = acceptance.into
                after = acceptance.after
                refusal = acceptance.refusal
            }
        }

        struct Indent: Encodable {
            var step: Double
            var minimumLabelWidth: Double
            var maxVisualLevels: Int
            var indentsTopLevel: Bool

            enum CodingKeys: String, CodingKey {
                case step
                case minimumLabelWidth = "minimum_label_width"
                case maxVisualLevels = "max_visual_levels"
                case indentsTopLevel = "indents_top_level"
            }

            init(_ indent: SidebarIndent) {
                step = Double(indent.step)
                minimumLabelWidth = Double(indent.minimumLabelWidth)
                maxVisualLevels = indent.maxVisualLevels
                indentsTopLevel = indent.indentsTopLevel
            }
        }

        struct Outline: Encodable {
            var indent: Indent
            var leading: Double
            var width: Double
        }

        /// `sidebar_geometry_new`.
        struct New: Encodable {
            var slots: [Slot]
            var acceptance: [String: Acceptance]
            var outline: Outline?

            init(_ geometry: SidebarDragGeometry) {
                slots = geometry.slots.map(Slot.init)
                acceptance = geometry.acceptance.mapValues(Acceptance.init)
                outline = geometry.outline.map {
                    Outline(indent: Indent($0.indent), leading: Double($0.leading), width: Double($0.width))
                }
            }
        }

        struct Registered: Decodable {
            var id: UInt64
        }

        /// `sidebar_geometry_hit`.
        struct Point: Encodable {
            var id: UInt64
            var x: Double
            var y: Double
        }

        /// `sidebar_geometry_beside`.
        struct Beside: Encodable {
            var id: UInt64
            var key: String
            var after: Bool
        }

        /// `sidebar_geometry_edge_y`.
        struct Edge: Encodable {
            var id: UInt64
            var top: Double
            var bottom: Double
            var x: Double
            var movingUp: Bool
            var gapY: Double?
            var gapHeight: Double
            var current: SidebarDocTarget?
            var reversing: Bool

            enum CodingKeys: String, CodingKey {
                case id
                case top
                case bottom
                case x
                case movingUp = "moving_up"
                case gapY = "gap_y"
                case gapHeight = "gap_height"
                case current
                case reversing
            }
        }

        /// `sidebar_geometry_base_y`.
        struct BaseY: Encodable {
            var y: Double
            var gapY: Double?
            var gapHeight: Double

            enum CodingKeys: String, CodingKey {
                case y
                case gapY = "gap_y"
                case gapHeight = "gap_height"
            }
        }

        /// `sidebar_geometry_free`.
        struct Free: Encodable {
            var id: UInt64
        }

        struct Freed: Decodable {}

        enum Zone: String, Decodable {
            case before
            case into
            case after

            var zone: SidebarDragGeometry.Zone {
                switch self {
                case .before: .before
                case .into: .into
                case .after: .after
                }
            }
        }

        /// A hit: its slot by index into the slots as sent.
        struct Hit: Decodable {
            var slot: Int
            var zone: Zone
            var target: SidebarDocTarget?
            var refusal: String?
        }

        /// The answer of `_hit` and `_beside`.
        struct HitReply: Decodable, SidebarGeometryReply {
            var hit: Hit?
            var gone: Bool?
        }

        /// The answer of `_edge_y` and `_base_y`.
        struct YReply: Decodable, SidebarGeometryReply {
            var y: Double?
            var gone: Bool?
        }
    }
}

nonisolated extension SidebarDocTarget: Decodable {
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(section: try c.decode(String.self, forKey: .section),
                  parent: try c.decodeIfPresent(String.self, forKey: .parent),
                  before: try c.decodeIfPresent(String.self, forKey: .before),
                  after: try c.decodeIfPresent(String.self, forKey: .after),
                  index: try c.decodeIfPresent(Int.self, forKey: .index))
    }
}
