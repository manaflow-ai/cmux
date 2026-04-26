import SwiftUI

@main
struct RightSidebarSampleContainerApp: App {
    var body: some Scene {
        WindowGroup {
            RightSidebarSampleContainerView()
                .frame(width: 420, height: 230)
        }
        .windowResizability(.contentSize)
    }
}

private struct RightSidebarSampleContainerView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "puzzlepiece.extension")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.green)

                VStack(alignment: .leading, spacing: 3) {
                    Text(String(localized: "sampleContainer.title", defaultValue: "cmux BYO Sidebar Sample"))
                        .font(.system(size: 18, weight: .semibold))
                    Text(String(localized: "sampleContainer.subtitle", defaultValue: "This app carries a cmux right sidebar extension."))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 7) {
                Label(
                    String(
                        localized: "sampleContainer.stepInstall",
                        defaultValue: "Build and register this app with the included script."
                    ),
                    systemImage: "hammer"
                )
                Label(
                    String(
                        localized: "sampleContainer.stepRefresh",
                        defaultValue: "Open cmux, choose the ExtensionKit sidebar, then refresh."
                    ),
                    systemImage: "arrow.clockwise"
                )
                Label(
                    String(
                        localized: "sampleContainer.stepSelect",
                        defaultValue: "Pick cmux BYO Sidebar Sample from the extension menu."
                    ),
                    systemImage: "cursorarrow.click"
                )
            }
            .font(.system(size: 12))

            Spacer(minLength: 0)
        }
        .padding(18)
    }
}
