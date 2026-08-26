import Foundation

/// Decodes an array of attach routes tolerantly.
///
/// Each element is decoded independently, and an element that fails strict
/// decoding is silently dropped instead of failing the whole array: an
/// unknown transport `kind` (peers running other releases still publish the
/// removed `iroh` kind), an unrecognized endpoint shape, or a route that
/// fails validation. Every payload that carries a route array (tickets,
/// registry and presence payloads, persisted stores, backup records) must
/// keep decoding when it contains routes this build cannot dial.
public struct CmxTolerantAttachRouteList: Decodable, Sendable {
    public let routes: [CmxAttachRoute]

    public init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var routes: [CmxAttachRoute] = []
        while !container.isAtEnd {
            if let route = try? container.decode(CmxAttachRoute.self) {
                routes.append(route)
            } else {
                // A failed decode does not advance the unkeyed cursor;
                // consume the element so the loop terminates.
                _ = try? container.decode(CmxDiscardedJSONValue.self)
            }
        }
        self.routes = routes
    }
}

/// Consumes one arbitrary JSON value of any shape without retaining it, so an
/// unkeyed decode cursor advances past an element that failed strict decoding.
struct CmxDiscardedJSONValue: Decodable {
    init(from decoder: any Decoder) throws {
        if let single = try? decoder.singleValueContainer() {
            if single.decodeNil() { return }
            if (try? single.decode(Bool.self)) != nil { return }
            if (try? single.decode(Double.self)) != nil { return }
            if (try? single.decode(String.self)) != nil { return }
        }
        // Object or array element: opening the matching container consumes it.
        if (try? decoder.container(keyedBy: DiscardKey.self)) != nil { return }
        _ = try? decoder.unkeyedContainer()
    }

    private struct DiscardKey: CodingKey {
        var stringValue: String
        var intValue: Int?

        init?(stringValue: String) {
            self.stringValue = stringValue
            self.intValue = nil
        }

        init?(intValue: Int) {
            self.stringValue = String(intValue)
            self.intValue = intValue
        }
    }
}
