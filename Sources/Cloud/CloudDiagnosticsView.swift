import CmuxCloud
import SwiftUI

struct CloudDiagnosticsView: View {
    let recorder: CloudOperationRecorder
    var devices: DeviceLinkDiagnostics? = nil

    var body: some View {
        CloudOperationDetailsView(operations: recorder.operations, devices: devices)
    }
}
