#if os(iOS)
import CmuxMobileDiagnostics
import Foundation

actor MobileFeedbackClient {
    private let settings: MobileFeedbackSettings?

    init(settings: MobileFeedbackSettings? = .live()) {
        self.settings = settings
    }

    func submit(
        email: String,
        message: String,
        diagnosticsReport: MobileDiagnosticsReport,
        photoAttachments: [MobileFeedbackPhotoAttachment],
        metadata: MobileFeedbackAppMetadata
    ) async throws {
        guard let settings else {
            throw MobileFeedbackSubmissionError.invalidEndpoint
        }

        let diagnosticsData = try diagnosticsPayload(from: diagnosticsReport.text)
        let totalPhotoBytes = photoAttachments.reduce(0) { $0 + $1.data.count }
        guard totalPhotoBytes <= MobileFeedbackSettings.targetTotalPhotoUploadBytes else {
            throw MobileFeedbackSubmissionError.photoPreparationFailed
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: settings.endpointURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        var body = Data()
        appendField("email", value: email, to: &body, boundary: boundary)
        appendField("message", value: message, to: &body, boundary: boundary)
        appendField("appVersion", value: metadata.appVersion, to: &body, boundary: boundary)
        appendField("appBuild", value: metadata.appBuild, to: &body, boundary: boundary)
        appendField("appCommit", value: metadata.appCommit, to: &body, boundary: boundary)
        appendField("bundleIdentifier", value: metadata.bundleIdentifier, to: &body, boundary: boundary)
        appendField("osVersion", value: metadata.osVersion, to: &body, boundary: boundary)
        appendField("locale", value: metadata.localeIdentifier, to: &body, boundary: boundary)
        appendField("hardwareModel", value: metadata.hardwareModel, to: &body, boundary: boundary)
        appendField("chip", value: "", to: &body, boundary: boundary)
        appendField("memoryGB", value: metadata.memoryGB, to: &body, boundary: boundary)
        appendField("architecture", value: metadata.architecture, to: &body, boundary: boundary)
        appendField("displayInfo", value: metadata.displayInfo, to: &body, boundary: boundary)

        appendFile(
            fieldName: "diagnostics",
            fileName: "cmux-diagnostics.txt",
            mimeType: "text/plain",
            data: diagnosticsData,
            to: &body,
            boundary: boundary
        )

        for attachment in photoAttachments {
            appendFile(
                fieldName: "attachments",
                fileName: attachment.fileName,
                mimeType: attachment.mimeType,
                data: attachment.data,
                to: &body,
                boundary: boundary
            )
        }

        body.append(Data("--\(boundary)--\r\n".utf8))
        request.httpBody = body

        let response: URLResponse
        do {
            (_, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError {
            throw MobileFeedbackSubmissionError.transport(error)
        } catch {
            throw MobileFeedbackSubmissionError.invalidResponse
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw MobileFeedbackSubmissionError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw MobileFeedbackSubmissionError.rejected(statusCode: httpResponse.statusCode)
        }
    }

    private func diagnosticsPayload(from reportText: String) throws -> Data {
        let data = Data(reportText.utf8)
        guard data.count > MobileFeedbackSettings.maxDiagnosticsAttachmentBytes else {
            return data
        }

        let marker = "\n\n[diagnostics truncated for feedback upload]\n\n"
        var headCount = min(reportText.count / 3, 80_000)
        var tailCount = min(reportText.count / 3, 160_000)

        while headCount > 0, tailCount > 0 {
            let truncated = String(reportText.prefix(headCount)) + marker + String(reportText.suffix(tailCount))
            let truncatedData = Data(truncated.utf8)
            if truncatedData.count <= MobileFeedbackSettings.maxDiagnosticsAttachmentBytes {
                return truncatedData
            }
            headCount = Int(Double(headCount) * 0.85)
            tailCount = Int(Double(tailCount) * 0.85)
        }

        throw MobileFeedbackSubmissionError.diagnosticsPreparationFailed
    }

    private func appendField(
        _ name: String,
        value: String,
        to body: inout Data,
        boundary: String
    ) {
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
        body.append(Data(value.utf8))
        body.append(Data("\r\n".utf8))
    }

    private func appendFile(
        fieldName: String,
        fileName: String,
        mimeType: String,
        data: Data,
        to body: inout Data,
        boundary: String
    ) {
        let sanitizedFileName = fileName.replacingOccurrences(of: "\"", with: "")

        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(
            Data(
                "Content-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(sanitizedFileName)\"\r\n".utf8
            )
        )
        body.append(Data("Content-Type: \(mimeType)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n".utf8))
    }
}
#endif
