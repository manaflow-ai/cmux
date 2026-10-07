import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The Rust host's agent pane rules (cmux-tui/crates/cmux-agent-pane-policy) must be this host's:
/// its `policy.json` lists equal ``AcpmuxPaneMethods``'s, and its shared case files
/// (`tests/cases/*.json`, which its own `tests/parity.rs` runs) give the same answers here.
@Suite struct AgentPanePolicyParityTests {
    /// The crate's directory, from this file's place in the repository.
    static let crate = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("cmux-tui/crates/cmux-agent-pane-policy")

    static func json(_ relative: String) throws -> Any {
        try JSONSerialization.jsonObject(with: Data(contentsOf: crate.appendingPathComponent(relative)), options: [.fragmentsAllowed])
    }

    /// A case file's cases; an empty file fails (it would pass every runner).
    static func cases(_ name: String) throws -> [[String: Any]] {
        let all = try #require(try json("tests/cases/\(name)") as? [[String: Any]])
        try #require(!all.isEmpty, "\(name) holds no cases")
        return all
    }

    /// One group of a case file, at least one case.
    static func group(_ all: [String: Any], _ key: String) throws -> [[String: Any]] {
        let cases = try #require(all[key] as? [[String: Any]], "no group \(key)")
        try #require(!cases.isEmpty, "group \(key) holds no cases")
        return cases
    }

    static func set(_ value: Any?) -> Set<String> { Set((value as? [String]) ?? []) }

    /// Two JSON values equal as JSON (numbers by value, objects unordered).
    static func same(_ a: Any?, _ b: Any?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case (is NSNull, is NSNull), (is NSNull, nil), (nil, is NSNull): return true
        case let (x as [String: Any], y as [String: Any]):
            return x.count == y.count && x.allSatisfy { key, value in y.keys.contains(key) && same(value, y[key]) }
        case let (x as [Any], y as [Any]):
            return x.count == y.count && zip(x, y).allSatisfy { same($0, $1) }
        case let (x as String, y as String): return x == y
        case let (x as NSNumber, y as NSNumber): return x == y
        default: return false
        }
    }

    @Test func thePolicyFileListsAreThisHostsLists() throws {
        let policy = try #require(try Self.json("policy.json") as? [String: Any])
        #expect(policy["pane_origin"] as? String == AcpmuxConnection.paneOrigin)
        #expect(policy["initialize"] as? String == AcpmuxPaneMethods.initialize)
        #expect(Self.set(policy["requests"]) == AcpmuxPaneMethods.requests)
        #expect(Self.set(policy["notifications"]) == AcpmuxPaneMethods.notifications)
        #expect(policy["maximum_frame_bytes"] as? Int == AcpmuxPaneMethods.maximumFrameBytes)
        #expect(policy["servers_key"] as? String == AcpmuxPaneMethods.serversKey)
        #expect(policy["gesture_ticket_key"] as? String == AcpmuxPaneMethods.gestureTicketKey)
        #expect(Self.set(policy["session_scoped"]) == AcpmuxPaneMethods.sessionScoped)
        #expect(Self.set(policy["optionally_session_scoped"]) == AcpmuxPaneMethods.optionallySessionScoped)
        #expect(Self.set(policy["source_scoped"]) == AcpmuxPaneMethods.sourceScoped)
        #expect(Self.set(policy["setting_methods"]) == AcpmuxPaneMethods.settingMethods)
        #expect(Self.set(policy["history_replies"]) == AcpmuxPermissionOptions.historyReplies)
        #expect(Self.set(policy["path_keys"]) == Set(AcpmuxPathPolicy.keys))
        let rules = try #require(policy["gesture_rules"] as? [String: String])
        #expect(Set(rules.keys) == Set(AcpmuxPaneMethods.gestureRules.keys))
        for (method, rule) in AcpmuxPaneMethods.gestureRules {
            let name = switch rule {
            case .always: "always"
            case .whenTrusting: "when_trusting"
            case .whenOptionAllows: "when_option_allows"
            case .whenDecisionAllows: "when_decision_allows"
            }
            #expect(rules[method] == name, "\(method)")
        }
        let known = try #require(policy["known_params"] as? [String: [String: [String]]])
        #expect(Set(known.keys) == Set(AcpmuxPaneMethods.knownParams.keys))
        for (method, entry) in AcpmuxPaneMethods.knownParams {
            #expect(Set(known[method]?["params"] ?? []) == entry.params, "\(method) params")
            #expect(Set(known[method]?["acpmux"] ?? []) == entry.acpmux, "\(method) acpmux")
        }
        let shapes = try #require(policy["reply_shapes"] as? [String: Any])
        #expect(Set(shapes.keys) == Set(AcpmuxPaneMethods.replyShapes.keys))
        func encode(_ shape: AcpmuxPaneMethods.ReplyShape) -> Any {
            switch shape {
            case .string: "string"
            case .list(let item): ["list": encode(item)]
            case .object(let fields): ["object": fields.mapValues(encode)]
            }
        }
        for (method, shape) in AcpmuxPaneMethods.replyShapes { #expect(Self.same(shapes[method], encode(shape)), "\(method)") }
    }

    /// What this host must give for case `c`: `swift_expect` while a stricter crate rule has not
    /// landed here (`swift_gap` names it; this test then fails when it lands, so the gap is closed
    /// in the case file), else `expect`.
    static func expected(_ c: [String: Any]) throws -> [String: Any] {
        try #require((c["swift_expect"] ?? c["expect"]) as? [String: Any])
    }

    static func checkFrame(_ c: [String: Any]) throws {
        let name = c["name"] as? String ?? "?"
        let text = try #require(c["text"] as? String)
        let got = AcpmuxPaneMethods.decide(text, isFirst: c["first"] as? Bool ?? false, localAppToken: c["token"] as? String)
        let expect = try expected(c)
        switch got {
        case .send(let sent):
            if expect["send"] as? String == "unchanged" {
                #expect(sent == text, "\(name)")
            } else {
                let parsed = try? JSONSerialization.jsonObject(with: Data(sent.utf8))
                #expect(expect["send"] != nil && same(parsed, expect["send"]), "\(name): sent \(sent)")
            }
        case .refuse(let error, let method, let requestID):
            #expect(error.rawValue == expect["refuse"] as? String, "\(name): \(error.rawValue)")
            #expect(method == expect["method"] as? String, "\(name) method \(method ?? "nil")")
            #expect(requestID == expect["id"] as? String, "\(name) id \(requestID ?? "nil")")
        }
    }

    static func checkParams(_ c: [String: Any]) {
        let modes = (c["mode_fields"] as? [String]).map(Set.init)
        #expect(AcpmuxPaneMethods.breaksParamsRule(c["frame"] as? [String: Any], modeFields: modes) == c["breaks"] as? Bool,
                "\(c["name"] ?? "?")")
    }

    static func checkGesture(_ c: [String: Any]) {
        let options = AcpmuxPermissionOptions()
        for case let deny as [String] in c["denies"] as? [Any] ?? [] {
            options.observe(["method": "_acpmux/permission_pending",
                             "params": ["permissionId": deny[0], "request": ["options": [["optionId": deny[1], "kind": "reject_once"]]]]],
                            replyTo: nil)
        }
        #expect(AcpmuxPaneMethods.needsGesture(c["frame"] as? [String: Any], options: options) == c["needs"] as? Bool,
                "\(c["name"] ?? "?")")
    }

    @Test func frames() throws {
        for c in try Self.cases("frames.json") { try Self.checkFrame(c) }
    }

    /// The facts of a checked frame in the case files' form.
    static func factsJSON(_ facts: AgentPaneTransport.Facts) -> [String: Any] {
        func opt(_ value: String?) -> Any { value ?? NSNull() }
        var pick: Any = NSNull()
        if let p = facts.pick {
            var params: Any = NSNull()
            if let scalars = p.params {
                params = scalars.mapValues { scalar -> Any in
                    switch scalar {
                    case .string(let s): s
                    case .bool(let b): b
                    case .number(let n): n
                    case .null: NSNull()
                    }
                }
            }
            pick = ["method": opt(p.method), "params": params]
        }
        var setting: Any = NSNull()
        if let s = facts.setting {
            let asked: [String: Any] = switch s.asked {
            case .mode(let mode): ["mode": mode]
            case .option(let id, let value): ["option": ["id": id, "value": value]]
            }
            setting = ["session_id": opt(s.sessionId), "config_id": s.configId, "value": opt(s.value), "asked": asked]
        }
        return [
            "is_first": facts.isFirst, "method": opt(facts.method), "page_id": opt(facts.pageID),
            "ticket": opt(facts.ticket), "other_meta": facts.otherMeta, "pick": pick,
            "session_id": opt(facts.sessionId), "needs_gesture": facts.needsGesture,
            "needs_path_check": facts.needsPathCheck, "setting": setting,
            "attach_session": opt(facts.attachSession), "foreign_source": facts.foreignSource,
            "handoff_id": opt(facts.handoffId), "harness_enable": facts.harnessEnable, "free": facts.free,
        ]
    }

    /// The full check in order (`tests/cases/check.json`, which the crate's `full_check_order`
    /// runs against `check_frame`) against ``AgentPaneTransport/checkOne(_:_:)``.
    @Test func fullCheckOrder() throws {
        let all = try Self.cases("check.json")
        #expect(all.count == 41, "check.json: the full order's 41 cases")
        for c in all {
            let name = c["name"] as? String ?? "?"
            let state = try #require(c["state"] as? [String: Any])
            let sessions = AcpmuxPaneSessions()
            for case let s as String in state["sessions"] as? [Any] ?? [] { sessions.add(s) }
            let options = AcpmuxPermissionOptions()
            for case let deny as [String] in state["denies"] as? [Any] ?? [] {
                options.observe(["method": "_acpmux/permission_pending",
                                 "params": ["permissionId": deny[0], "request": ["options": [["optionId": deny[1], "kind": "reject_once"]]]]],
                                replyTo: nil)
            }
            let snapshot = AgentPaneTransport.Snapshot(
                isFirst: state["first"] as? Bool ?? false, localAppToken: state["token"] as? String,
                modeFields: (state["mode_fields"] as? [String]).map(Set.init), sessions: sessions, options: options)
            let expect = try Self.expected(c)
            switch AgentPaneTransport.checkOne(try #require(c["text"] as? String), snapshot) {
            case .refuse(let decision, let spend):
                guard case .refuse(let error, let method, let requestID) = decision else {
                    Issue.record("\(name): refused with \(decision)")
                    continue
                }
                #expect(error.rawValue == expect["refuse"] as? String, "\(name): \(error.rawValue)")
                #expect(method == expect["method"] as? String, "\(name) method")
                #expect(requestID == expect["id"] as? String, "\(name) id")
                #expect(spend == expect["spend"] as? String, "\(name) spend")
            case .frame(let facts, let box):
                #expect(expect["refuse"] == nil, "\(name): not refused")
                let sent = box.encoded(id: nil).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) }
                #expect(Self.same(sent, expect["frame"]), "\(name) frame")
                #expect(Self.same(Self.factsJSON(facts), expect["facts"]), "\(name) facts \(Self.factsJSON(facts))")
            }
        }
    }

    /// The pane's scope and the source rule (`tests/cases/sources.json`, which the crate's
    /// `scope_and_sources` runs against `PaneSessions`) against ``AcpmuxPaneSessions``.
    @Test func scopeAndSources() throws {
        for c in try Self.cases("sources.json") {
            let name = c["name"] as? String ?? "?"
            let sessions = AcpmuxPaneSessions()
            for case let step as [String: Any] in c["steps"] as? [Any] ?? [] {
                if let session = step["add"] as? String {
                    sessions.add(session)
                } else if let sent = step["sent"] as? [String: Any] {
                    sessions.sent(method: sent["method"] as? String ?? "", id: sent["id"] as? String,
                                  handoff: sent["handoff"] as? String, owned: sent["owned"] as? Bool ?? false)
                } else if let frame = step["observe"] as? [String: Any] {
                    sessions.observe(frame)
                }
            }
            let holds = c["holds"] as? [[Any]] ?? []
            let contains = c["contains"] as? [[Any]] ?? []
            #expect(holds.count + contains.count > 0, "\(name) checks nothing")
            for h in holds {
                #expect(sessions.holdsSource(h[0] as? [String: Any] ?? [:]) == h[1] as? Bool, "\(name) holds \(h[0])")
            }
            for k in contains {
                #expect(sessions.contains(k[0] as? String ?? "") == k[1] as? Bool, "\(name) contains \(k[0])")
            }
        }
    }

    @Test func paramsRule() throws {
        for c in try Self.cases("params.json") { Self.checkParams(c) }
    }

    @Test func gestures() throws {
        for c in try Self.cases("gestures.json") { Self.checkGesture(c) }
    }

    /// AGENT-TRUST-GATE (`tests/cases/trust_gate.json`; its description cites the sources): the pane is
    /// LocalApp-origin only through this host's token, the page writes neither the token nor a forward
    /// mark, Trust needs a gesture and Don't trust does not, and the gate's refusals reach the page as
    /// acpmux wrote them (no ``AcpmuxPaneMethods/replyShapes`` entry rebuilds them).
    @Test func trustGate() throws {
        let all = try #require(try Self.json("tests/cases/trust_gate.json") as? [String: Any])
        for c in try Self.group(all, "frames") { try Self.checkFrame(c) }
        for c in try Self.group(all, "params") { Self.checkParams(c) }
        for c in try Self.group(all, "gestures") { Self.checkGesture(c) }
        let unfiltered = try #require(all["unfiltered"] as? [String])
        #expect(!unfiltered.isEmpty)
        for method in unfiltered { #expect(AcpmuxPaneMethods.replyShapes[method] == nil, "\(method)") }
    }

    @Test func permissionOptions() throws {
        for c in try Self.cases("options.json") {
            let options = AcpmuxPermissionOptions()
            for case let frame as [String: Any] in c["frames"] as? [Any] ?? [] {
                options.observe(frame["frame"] as? [String: Any] ?? [:], replyTo: frame["reply_to"] as? String)
            }
            for case let check as [Any] in c["checks"] as? [Any] ?? [] {
                let (p, o, deny) = (check[0] as? String ?? "", check[1] as? String ?? "", check[2] as? Bool)
                #expect(options.isDeny(permissionId: p, optionId: o) == deny, "\(c["name"] ?? "?") \(p)/\(o)")
            }
        }
    }

    @Test func replies() throws {
        for c in try Self.cases("replies.json") {
            let shape = try #require(AcpmuxPaneMethods.replyShapes[c["method"] as? String ?? ""])
            let text = AcpmuxPaneMethods.filteredReply(c["reply"] as? [String: Any] ?? [:], shape: shape, pageID: c["page_id"] as? String ?? "")
            let parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8))
            #expect(Self.same(parsed, c["expected"]), "\(c["name"] ?? "?"): \(text)")
        }
    }

    @Test func ticketsPromptMetaAndSettings() throws {
        for c in try Self.cases("tickets.json") {
            let name = c["name"] as? String ?? "?"
            let frame = try #require(c["frame"] as? [String: Any])
            let taken = AcpmuxPaneMethods.takeGestureTicket(frame)
            #expect(taken.ticket == c["ticket"] as? String, "\(name) ticket")
            #expect(taken.otherMeta == c["other_meta"] as? Bool, "\(name) other meta")
            #expect(Self.same(taken.object, c["without_ticket"]), "\(name) without ticket")
            #expect(Self.same(AcpmuxPaneMethods.strippingPromptMeta(frame), c["prompt_stripped"]), "\(name) prompt")
            let setting = AcpmuxPaneMethods.requestedSetting(frame)
            if let want = c["setting"] as? [String: Any] {
                #expect(setting?.sessionId == want["session_id"] as? String, "\(name) session")
                #expect(setting?.configId == want["config_id"] as? String, "\(name) config")
                #expect(setting?.value == want["value"] as? String, "\(name) value")
            } else {
                #expect(setting == nil, "\(name) setting")
            }
        }
    }

    @Test func sessionScope() throws {
        for c in try Self.cases("sessions.json") {
            let sessions = AcpmuxPaneSessions()
            for case let s as String in c["sessions"] as? [Any] ?? [] { sessions.add(s) }
            let refused = AgentPaneTransport.sessionRefusal(c["frame"] as? [String: Any] ?? [:], sessions: sessions)
            #expect((refused != nil) == c["refused"] as? Bool, "\(c["name"] ?? "?")")
            if let refused {
                #expect(refused == .refuse(.sessionNotInPane, method: (c["frame"] as? [String: Any])?["method"] as? String, requestID: "4"))
            }
        }
    }

    @Test func environmentTokensAndSockets() throws {
        let e = try #require(try Self.json("tests/cases/environment.json") as? [String: Any])
        for key in ["tag_slugs", "tokens", "sockets", "resolve"] {
            #expect(!((e[key] as? [Any]) ?? []).isEmpty, "environment.json group \(key) holds no cases")
        }
        for case let t as [Any] in e["tag_slugs"] as? [Any] ?? [] {
            #expect(AcpmuxEnvironment.tagSlug(t[0] as? String ?? "") == t[1] as? String, "tag \(t[0])")
        }
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("agent-pane-policy-parity-\(getpid())")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home.appendingPathComponent("run"), withIntermediateDirectories: true)
        for case let t as [Any] in e["tokens"] as? [Any] ?? [] {
            try Data((t[0] as? String ?? "").utf8).write(to: AcpmuxLocalAppToken.path(home: home))
            #expect(AcpmuxLocalAppToken.read(home: home) == t[1] as? String, "token \(t[0])")
        }
        for case let s as [Any] in e["sockets"] as? [Any] ?? [] {
            let got = AcpmuxEnvironment.defaultSocketPath(home: URL(fileURLWithPath: s[0] as? String ?? "", isDirectory: true),
                                                          uid: UInt32(s[1] as? Int ?? 0))
            #expect(got == s[2] as? String, "socket \(s[0])")
        }
        for case let r as [String: Any] in e["resolve"] as? [Any] ?? [] {
            let executables = Set(r["executables"] as? [String] ?? [])
            let got = AcpmuxEnvironment.resolve(
                tag: r["tag"] as? String,
                bundledBinDirectory: (r["bundled"] as? String).map { URL(fileURLWithPath: $0, isDirectory: true) },
                environment: r["env"] as? [String: String] ?? [:],
                userHome: URL(fileURLWithPath: r["user_home"] as? String ?? "", isDirectory: true),
                uid: UInt32(r["uid"] as? Int ?? 0),
                isExecutable: { executables.contains($0) })
            let name = r["name"] as? String ?? "?"
            guard let want = r["expect"] as? [String: Any] else { #expect(got == nil, "\(name)"); continue }
            #expect(got?.executable.path == want["executable"] as? String, "\(name) executable")
            #expect(got?.home.path == want["home"] as? String, "\(name) home \(got?.home.path ?? "nil")")
            #expect(got?.socketPath == want["socket"] as? String, "\(name) socket")
            #expect(got?.daemonArguments == want["args"] as? [String], "\(name) args")
        }
    }

    @Test func theRefusalFrame() throws {
        let text = AcpmuxPaneMethods.refusal(requestID: #""r-1""#, error: .methodRefused, method: "_acpmux/peer_add", rootRequested: true)
        let parsed = try JSONSerialization.jsonObject(with: Data(text.utf8))
        let expected: [String: Any] = ["jsonrpc": "2.0", "id": "r-1", "error": [
            "code": -32601, "message": "Refused by the cmux host",
            "data": ["code": "transport.method_refused", "origin": "native", "method": "_acpmux/peer_add", "rootRequested": true],
        ]]
        #expect(Self.same(parsed, expected))
    }
}
