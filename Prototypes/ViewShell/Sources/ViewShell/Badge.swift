// The shell's own native view: a badge in each window's titlebar naming its size and state.
// It is the live code demo too (README.md, "Live code"): edit `content`, run inject.sh on this
// file, and every open window redraws it with no relaunch.
import SwiftUI

struct PreviewBadge: View {
    let text: String

    // Live code: `body` is always an `AnyView`, so a patch may change what `content` builds (its
    // type as well as its values): the executable knows only `AnyView`, and the patch's `body`
    // wraps the patch's own `content`.
    var body: some View { AnyView(content) }

    @ViewBuilder private var content: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Capsule().fill(.quaternary))
    }
}
