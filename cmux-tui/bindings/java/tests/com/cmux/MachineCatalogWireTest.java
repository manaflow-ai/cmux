package com.cmux;

import java.io.EOFException;
import java.io.IOException;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.BlockingQueue;
import java.util.concurrent.LinkedBlockingQueue;

final class MachineCatalogWireTest {
    private static final String OWNER = "machine_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    private MachineCatalogWireTest() {}
    static void run() {
        Peer peer = new Peer();
        Snapshots.MachineSnapshot rich;
        try (Client client = Client.builder().transport(peer).build()) {
            client.listMachines(Options.Read.defaults());
            client.listMachinesWith(new Options.MachineRead(true));
            client.listMachinesWith(Options.MachineRead.defaults());
            Machine owner = client.machine(Selector.id(new Ids.MachineId(OWNER)));
            owner.refresh();
            rich = owner.refresh(new Options.MachineRead(true));
            owner.refresh(Options.MachineRead.defaults());
        }
        if (peer.sent.size() != 6) throw new AssertionError("unexpected request count");
        for (int index = 0; index < 6; index++) {
            Map<String,Object> expected = new HashMap<>();
            if (index >= 3) expected.put("machine", OWNER);
            if (index == 1 || index == 4) expected.put("catalog", true);
            if (!expected.equals(peer.sent.get(index).get("params"))) throw new AssertionError("wire request " + index + ": " + peer.sent.get(index));
            if (peer.sent.get(index).containsKey("idempotency_key")) throw new AssertionError("read acquired a mutation key");
        }
        if (!rich.platform().orElseThrow().os().orElseThrow().equals("linux")) throw new AssertionError("explicit metadata lost");
    }
    private static final class Peer implements Transport {
        final List<Map<String,Object>> sent = new ArrayList<>();
        final BlockingQueue<Map<String,Object>> replies = new LinkedBlockingQueue<>();
        public synchronized void send(Map<String,Object> request) {
            sent.add(new HashMap<>(request));
            @SuppressWarnings("unchecked") Map<String,Object> params = (Map<String,Object>) request.get("params");
            Map<String,Object> owner = new HashMap<>(Map.of("id",OWNER,"name","owner","origin","local","status","running","connectable",true,"deleted",false,"recoverable",false));
            if (Boolean.TRUE.equals(params.get("catalog"))) owner.put("platform",Map.of("os","linux"));
            Object result = request.get("operation").equals("machine.list") ? List.of(owner) : owner;
            replies.add(Map.of("protocol","cmux.protocol/2","type","response","id",request.get("id"),"ok",true,"result",result));
        }
        public Map<String,Object> receive() throws IOException {
            try {
                Map<String,Object> reply = replies.take();
                if (reply.isEmpty()) throw new EOFException();
                return reply;
            } catch (InterruptedException error) { Thread.currentThread().interrupt(); throw new IOException(error); }
        }
        public void close() { replies.offer(Map.of()); }
    }
}
