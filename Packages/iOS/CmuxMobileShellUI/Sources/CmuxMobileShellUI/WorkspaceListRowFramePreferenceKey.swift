import CmuxMobileShellModel
import SwiftUI

struct WorkspaceListRowFramePreferenceKey: PreferenceKey {
    static let defaultValue: [MobileWorkspaceDropRowFrame] = []

    static func reduce(
        value: inout [MobileWorkspaceDropRowFrame],
        nextValue: () -> [MobileWorkspaceDropRowFrame]
    ) {
        value.append(contentsOf: nextValue())
    }
}

extension View {
    func workspaceListDropFrame(
        kind: MobileWorkspaceDropRowKind,
        coordinateSpace: String
    ) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: WorkspaceListRowFramePreferenceKey.self,
                    value: [MobileWorkspaceDropRowFrame(
                        kind: kind,
                        frame: proxy.frame(in: .named(coordinateSpace))
                    )]
                )
            }
        }
    }
}
