import Darwin
import Foundation
import Testing
@testable import CmuxControlSocket

@Suite("CodeRouter handoff protocol")
struct CodeRouterHandoffProtocolTests {
    private let protocolCodec = CodeRouterHandoffProtocol()
    private let launchPolicy = CodeRouterLaunchPolicy()
    private let debugIdentityPolicy = CodeRouterDebugServerIdentityPolicy()
    private let capability: String
    private let nonce: Data
    private let challenge = Data(repeating: 0x43, count: 32)
    private let processID: pid_t = 42
    private let processStart: UInt64 = 0x0102_0304_0506_0708
    private let teamBinding = String(repeating: "a", count: 64)

    init() {
        nonce = Data(repeating: 0x41, count: 32)
        let tag = Data(repeating: 0x42, count: 32)
        capability = "v1.\(SocketClientCapabilityProof.encodeBase64URL32(nonce)!).\(SocketClientCapabilityProof.encodeBase64URL32(tag)!)"
    }

    @Test("validates the exact Darwin socket path limit")
    func socketPathLimit() {
        let pathWith103Bytes = "/" + String(repeating: "a", count: 102)
        let pathWith104Bytes = "/" + String(repeating: "a", count: 103)

        #expect(protocolCodec.socketPathIsValid(pathWith103Bytes))
        #expect(!protocolCodec.socketPathIsValid(pathWith104Bytes))
        #expect(!protocolCodec.socketPathIsValid("relative.sock"))
        #expect(!protocolCodec.socketPathIsValid("/tmp/cmux\n.sock"))
        #expect(!protocolCodec.socketPathIsValid("/tmp/cmux\u{200B}.sock"))
        #expect(protocolCodec.socketPathIsValid("/tmp/cmux\u{E0101}.sock"))
    }

    @Test("builds the exact proof request")
    func proofRequest() throws {
        let context = try #require(makeContext())

        #expect(Set(context.requestParams.keys) == [
            "protocolVersion",
            "capabilityNonce",
            "clientChallenge",
            "clientProcessID",
            "clientProcessStartAbsoluteTime",
            "clientProof",
        ])
        #expect(context.requestParams["protocolVersion"] as? Int == 2)
        #expect(context.requestParams["clientProcessID"] as? Int == 42)
        #expect(
            context.requestParams["clientProcessStartAbsoluteTime"] as? String
                == "0102030405060708"
        )
        #expect(
            SocketClientCapabilityProof.verifiesClientProof(
                try #require(context.requestParams["clientProof"] as? String),
                capability: capability,
                nonce: nonce,
                challenge: challenge,
                processID: processID,
                processStartAbsoluteTime: processStart
            )
        )
    }

    @Test("accepts only a signed exact success")
    func signedSuccess() throws {
        let context = try #require(makeContext())
        let proof = try #require(SocketClientCapabilityProof.serverProof(
            capability: capability,
            nonce: nonce,
            challenge: challenge,
            processID: processID,
            processStartAbsoluteTime: processStart,
            teamBinding: teamBinding
        ))
        let valid: [String: Any] = [
            "id": SocketClientCapabilityProof.requestID,
            "ok": true,
            "result": [
                "armed": true,
                "protocolVersion": 2,
                "teamBinding": teamBinding,
                "serverProof": proof,
            ],
        ]

        #expect(
            protocolCodec.verifyResponse(valid, context: context)
                == .armed(teamBinding: teamBinding)
        )

        var tampered = valid
        var tamperedResult = try #require(valid["result"] as? [String: Any])
        tamperedResult["serverProof"] = String(repeating: "f", count: 64)
        tampered["result"] = tamperedResult
        #expect(protocolCodec.verifyResponse(tampered, context: context) == nil)

        var extended = valid
        var extendedResult = try #require(valid["result"] as? [String: Any])
        extendedResult["unexpected"] = true
        extended["result"] = extendedResult
        #expect(protocolCodec.verifyResponse(extended, context: context) == nil)
    }

    @Test("accepts only an allow-listed signed error")
    func signedError() throws {
        let context = try #require(makeContext())
        let code = "team_required"
        let proof = try #require(SocketClientCapabilityProof.serverErrorProof(
            capability: capability,
            nonce: nonce,
            challenge: challenge,
            processID: processID,
            processStartAbsoluteTime: processStart,
            code: code
        ))
        let valid: [String: Any] = [
            "id": SocketClientCapabilityProof.requestID,
            "ok": false,
            "error": [
                "code": code,
                "message": "Not used before proof verification",
                "data": ["serverProof": proof],
            ],
        ]

        #expect(
            protocolCodec.verifyResponse(valid, context: context)
                == .signedError(code: code)
        )

        var unsigned = valid
        var error = try #require(valid["error"] as? [String: Any])
        error.removeValue(forKey: "data")
        unsigned["error"] = error
        #expect(protocolCodec.verifyResponse(unsigned, context: context) == nil)
    }

    @Test("validates the exact raw response schema")
    func rawResponseSchema() {
        let proof = String(repeating: "b", count: 64)
        let validSuccess = #"{"id":"coderouter-handoff-arm","ok":true,"result":{"armed":true,"protocolVersion":2,"teamBinding":"\#(teamBinding)","serverProof":"\#(proof)"}}"#
        let validError = #"{"id":"coderouter-handoff-arm","ok":false,"error":{"code":"team_required","message":"ignored","data":{"serverProof":"\#(proof)"}}}"#

        #expect(protocolCodec.responseRawShapeIsValid(validSuccess))
        #expect(protocolCodec.responseRawShapeIsValid(validError))
        #expect(!protocolCodec.responseRawShapeIsValid(" \(validSuccess)"))
        #expect(!protocolCodec.responseRawShapeIsValid("\(validError)\u{00a0}"))

        let invalidForms = [
            validSuccess.replacingOccurrences(of: #""ok":true"#, with: #""ok":1"#),
            validSuccess.replacingOccurrences(of: #""armed":true"#, with: #""armed":1"#),
            validSuccess.replacingOccurrences(of: #""protocolVersion":2"#, with: #""protocolVersion":2.0"#),
            validSuccess.replacingOccurrences(of: #""protocolVersion":2"#, with: #""protocolVersion":2e0"#),
            validSuccess.replacingOccurrences(of: #""ok":true"#, with: #""ok":true,"ok":true"#),
            validSuccess.replacingOccurrences(of: #""armed":true"#, with: #""armed":true,"armed":true"#),
            validSuccess.replacingOccurrences(of: #""armed":true"#, with: #""\u0061rmed":false,"armed":true"#),
            validSuccess.replacingOccurrences(of: #""serverProof":"\#(proof)""#, with: #""serverProof":"\#(proof)","unexpected":true"#),
        ]
        for invalid in invalidForms {
            #expect(!protocolCodec.responseRawShapeIsValid(invalid))
        }
    }

    @Test("classifies only exact provider commands")
    func routedCommandClassification() {
        #expect(launchPolicy.commandRequiresHandoff(["codex"]))
        #expect(launchPolicy.commandRequiresHandoff(["opencode", "--help"]))
        #expect(launchPolicy.commandRequiresHandoff(["pi", "arg"]))
        #expect(!launchPolicy.commandRequiresHandoff([]))
        #expect(!launchPolicy.commandRequiresHandoff(["login"]))
        #expect(!launchPolicy.commandRequiresHandoff(["Codex"]))
    }

    @Test("builds the hidden argv without shell parsing")
    func hiddenArguments() {
        let arm = CodeRouterHandoffProtocol.Arm(
            socketPath: "/tmp/cmux.sock",
            teamBinding: teamBinding
        )
        #expect(
            launchPolicy.launchArguments(
                commandArgs: ["codex", "--", "echo; touch no"],
                handoff: arm
            ) == [
                "__cmux-handoff-v2",
                "/tmp/cmux.sock",
                teamBinding,
                "--",
                "codex",
                "--",
                "echo; touch no",
            ]
        )
    }

    @Test("scrubs routed secrets but preserves naked provider credentials")
    func childEnvironment() {
        let input = [
            "PATH": "/usr/bin",
            "OPENAI_API_KEY": "provider",
            "GITHUB_TOKEN": "tool",
            "AWS_REGION": "us-west-2",
            "AWS_PROFILE": "dev",
            "AWS_ACCESS_KEY_ID": "secret",
            "CMUX_SOCKET_CAPABILITY": "capability",
            "CODEROUTER_HANDOFF_FD": "3",
            "DYLD_LIBRARY_PATH": "/tmp/injected",
            "https_proxy": "https://proxy.invalid",
            "SSL_CERT_FILE": "/tmp/ca.pem",
            "SSLKEYLOGFILE": "/tmp/keys",
        ]
        let routed = launchPolicy.childEnvironment(
            input,
            forHandoff: true
        )
        #expect(routed["PATH"] == "/usr/bin")
        #expect(routed["AWS_REGION"] == "us-west-2")
        #expect(routed["AWS_PROFILE"] == "dev")
        #expect(routed["OPENAI_API_KEY"] == nil)
        #expect(routed["GITHUB_TOKEN"] == nil)
        #expect(routed["AWS_ACCESS_KEY_ID"] == nil)
        #expect(routed["CMUX_SOCKET_CAPABILITY"] == nil)
        #expect(routed["CODEROUTER_HANDOFF_FD"] == nil)
        #expect(routed["DYLD_LIBRARY_PATH"] == nil)
        #expect(routed["https_proxy"] == nil)
        #expect(routed["SSL_CERT_FILE"] == nil)
        #expect(routed["SSLKEYLOGFILE"] == nil)

        let naked = launchPolicy.childEnvironment(
            input,
            forHandoff: false,
            preserveProviderCredentials: true
        )
        #expect(naked["OPENAI_API_KEY"] == "provider")
        #expect(naked["GITHUB_TOKEN"] == "tool")
        #expect(naked["AWS_ACCESS_KEY_ID"] == "secret")
        #expect(naked["CMUX_SOCKET_CAPABILITY"] == nil)
        #expect(naked["DYLD_LIBRARY_PATH"] == nil)
    }

    @Test("allows only the matching company-signed tagged Debug server")
    func debugServerIdentity() {
        let identifier = "com.cmuxterm.app.debug.coderouter-dogfood"
        #expect(debugIdentityPolicy.isAllowed(
            identifier: identifier,
            teamIdentifier: "7WLXT3NR37",
            expectedBundleIdentifier: identifier
        ))
        #expect(!debugIdentityPolicy.isAllowed(
            identifier: identifier,
            teamIdentifier: "OTHERTEAM",
            expectedBundleIdentifier: identifier
        ))
        #expect(!debugIdentityPolicy.isAllowed(
            identifier: "com.cmuxterm.app.debug.other",
            teamIdentifier: "7WLXT3NR37",
            expectedBundleIdentifier: identifier
        ))
        #expect(!debugIdentityPolicy.isAllowed(
            identifier: "com.cmuxterm.app",
            teamIdentifier: "7WLXT3NR37",
            expectedBundleIdentifier: "com.cmuxterm.app"
        ))
    }

    private func makeContext() -> CodeRouterHandoffProtocol.ProofContext? {
        protocolCodec.makeProofContext(
            capability: capability,
            challenge: challenge,
            processID: processID,
            processStartAbsoluteTime: processStart
        )
    }
}
