#!/usr/bin/env python3
"""mac-app-relay: a request line reaches the app through the gate client and
its answer comes back; a gate that cannot reach the Mac gives an
`app.unreachable` answer that says why. The gate client here is a stand-in
that runs the Mac side locally (`bash -c`), against a stand-in app socket.

run: python3 -I deploy/cloud-vm/tests/mac_app_relay_test.py
"""
import importlib.util
import json
import os
import socket
import socketserver
import stat
import sys
import tempfile
import threading
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("relay", os.path.join(HERE, "..", "mac-app-relay.py"))
relay = importlib.util.module_from_spec(spec)
spec.loader.exec_module(relay)


class FakeApp(socketserver.StreamRequestHandler):
    def handle(self):
        for line in self.rfile:
            req = json.loads(line)
            if req["method"] == "system.ping":
                answer = {"id": req["id"], "ok": True, "result": {"app": "cmux-next", "pong": True}}
            else:
                answer = {"id": req["id"], "ok": True, "result": {"echo": req["params"]}}
            self.wfile.write((json.dumps(answer) + "\n").encode())


class AppServer(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True


def ask(path, *requests):
    s = socket.socket(socket.AF_UNIX)
    s.settimeout(30)
    s.connect(path)
    f = s.makefile("rwb")
    answers = []
    for r in requests:
        f.write((json.dumps(r) + "\n").encode())
        f.flush()
        answers.append(json.loads(f.readline()))
    s.close()
    return answers


class RelayTest(unittest.TestCase):
    def setUp(self):
        # Short: macOS limits a socket path to 103 bytes.
        self.dir = tempfile.mkdtemp(prefix="mar", dir="/tmp")
        self.app_path = os.path.join(self.dir, "app.sock")
        self.app = AppServer(self.app_path, FakeApp)
        threading.Thread(target=self.app.serve_forever, daemon=True).start()
        # The gate client: drops its own flags, runs the command after `--`.
        self.mac = os.path.join(self.dir, "mac")
        with open(self.mac, "w") as f:
            f.write('#!/bin/bash\nwhile [ "$1" != "--" ]; do shift; done; shift\n'
                    '[ -f "$(dirname "$0")/asleep" ] && { echo "mac: cannot reach the Mac gate at '
                    'http://100.82.214.112:7420: timed out (is the laptop awake?)" >&2; exit 125; }\n'
                    'exec bash -c "$1"\n')
        os.chmod(self.mac, stat.S_IRWXU)

    def tearDown(self):
        self.app.shutdown()
        self.app.server_close()

    def start_relay(self, mac_socket, socket_mode=None):
        listen = os.path.join(self.dir, "relay.sock")
        ready = threading.Event()
        r = relay.Relay([self.mac], mac_socket, 5)
        args = (listen, r, ready) if socket_mode is None else (listen, r, ready, socket_mode)
        threading.Thread(target=relay.serve, args=args, daemon=True).start()
        self.assertTrue(ready.wait(5))
        return listen

    def test_diagnostics_reach_the_app_but_actions_do_not(self):
        listen = self.start_relay(self.app_path)
        self.assertEqual(stat.S_IMODE(os.stat(listen).st_mode), 0o600)
        ping, run = ask(listen,
                        {"id": 1, "method": "system.ping", "params": {}},
                        {"id": 2, "method": "action.run", "params": {
                            "action": "tab new page", "cli": True, "origin": "mcp", "after": "sync"}})
        self.assertEqual(ping, {"id": 1, "ok": True, "result": {"app": "cmux-next", "pong": True}})
        self.assertFalse(run["ok"])
        self.assertEqual(run["error"]["code"], "app.remote_denied")

    def test_non_allowlisted_methods_and_actions_never_reach_the_mac(self):
        listen = self.start_relay(self.app_path)
        requests = [
            {"id": 10, "method": "settings.set", "params": {"path": "x", "value": True}},
            {"id": 11, "method": "action.run", "params": {
                "action": "servers add", "cli": True, "origin": "mcp", "args": {"code": "ABCD-EFGH"}}},
            {"id": 12, "method": "action.run", "params": {
                "action": "tab new page", "cli": True, "origin": "cli"}},
            {"id": 13, "method": "action.run", "params": {
                "action": "tab new page", "cli": True, "origin": "mcp", "focus": True}},
        ]
        for answer in ask(listen, *requests):
            self.assertFalse(answer["ok"])
            self.assertEqual(answer["error"]["code"], "app.remote_denied")
            self.assertFalse(answer["error"]["retryable"])

    def test_relay_socket_can_be_group_shared_without_becoming_world_accessible(self):
        listen = self.start_relay(self.app_path, 0o660)
        self.assertEqual(stat.S_IMODE(os.stat(listen).st_mode), 0o660)

    def test_an_unreachable_mac_answers_with_the_reason(self):
        open(os.path.join(self.dir, "asleep"), "w").close()
        listen = self.start_relay(self.app_path)
        (answer,) = ask(listen, {"id": 7, "method": "system.ping", "params": {}})
        self.assertEqual(answer["id"], 7)
        self.assertFalse(answer["ok"])
        self.assertEqual(answer["error"]["code"], "app.unreachable")
        self.assertIn("is the laptop awake", answer["error"]["message"])

    def test_no_app_on_the_mac_answers_with_the_reason(self):
        listen = self.start_relay(os.path.join(self.dir, "missing.sock"))
        (answer,) = ask(listen, {"id": 3, "method": "system.ping", "params": {}})
        self.assertFalse(answer["ok"])
        self.assertIn("missing.sock", answer["error"]["message"])


if __name__ == "__main__":
    unittest.main()
