package com.cmux;

import java.util.HashMap;
import java.util.List;
import java.util.Map;

public final class MachineCatalogTest {
    private MachineCatalogTest() {}
    public static void main(String[] args) {
        Map<String, Object> record = new HashMap<>(Map.of(
            "id", "machine_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "name", "server", "origin", "local",
            "status", "running", "connectable", true, "deleted", false, "recoverable", false));
        Snapshots.MachineSnapshot legacy = Client.decodeMachine(record);
        if (legacy.platform().isPresent() || !legacy.capabilities().isEmpty()) throw new AssertionError("legacy defaults");
        record.put("platform", Map.of("os", "linux", "arch", "aarch64"));
        record.put("capabilities", List.of("terminal", "agent_session"));
        for (String origin : List.of("local", "cloud", "ssh", "server")) {
            record.put("origin", origin);
            Snapshots.MachineSnapshot machine = Client.decodeMachine(record);
            if (!machine.origin().equals(origin) || !machine.platform().orElseThrow().os().orElseThrow().equals("linux")
                || !machine.capabilities().equals(List.of("terminal", "agent_session"))) throw new AssertionError("owner metadata lost");
        }
        record.put("platform", Map.of("path", "/private"));
        try { Client.decodeMachine(record); throw new AssertionError("unknown metadata accepted"); }
        catch (ProtocolError expected) { /* Refusal is the expected result. */ }
        MachineCatalogWireTest.run();
    }
}
