package com.cmux.raw.examples;

import com.cmux.raw.CmuxClient;
import com.cmux.raw.UInt64;
import com.cmux.raw.IdentifyResult;
import com.cmux.raw.ReadScreenRequest;
import com.cmux.raw.SendRequest;

public final class Quickstart {
    private Quickstart() {}

    public static void main(String[] args) throws Exception {
        try (CmuxClient client = CmuxClient.builder().build()) {
            IdentifyResult server = client.identify();
            System.out.println("cmux protocol " + server.protocol());

            UInt64 surface = UInt64.parse(args[0]);
            client.send(
                SendRequest.builder()
                    .surface(surface)
                    .text("printf 'hello from Java\\r'")
                    .build()
            );
            System.out.println(
                client.readScreen(ReadScreenRequest.builder().surface(surface).build()).text()
            );
        }
    }
}
