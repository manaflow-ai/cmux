import Foundation

/// One reflection read (`GET /api/vm/<id>/reflection[/<path>]`): the HTTP status and the
/// JSON body as sent. A 404 with `{error: "not_found", paths: […]}` is a normal result
/// (an unknown reflection path), so the CLI can print the paths that do exist.
struct VMReflectionResult: Sendable {
    let statusCode: Int
    let body: Data

    var object: [String: Any] {
        ((try? JSONSerialization.jsonObject(with: body, options: [])) as? [String: Any]) ?? [:]
    }
}
