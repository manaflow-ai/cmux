/// Client-side viewer routes derived without expanding the artifact wire kind.
enum ChatArtifactPreviewRoute: Equatable, Sendable {
    case folder
    case image
    case pdf
    case media
    case markdown
    case text
    case quickLook
    case binary
}
