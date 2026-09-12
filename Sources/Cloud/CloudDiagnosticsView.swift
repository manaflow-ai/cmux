import SwiftUI

struct CloudDiagnosticsView: View {
    let recorder: CloudOperationRecorder

    var body: some View {
        CloudOperationDetailsView(operations: recorder.operations)
    }
}
