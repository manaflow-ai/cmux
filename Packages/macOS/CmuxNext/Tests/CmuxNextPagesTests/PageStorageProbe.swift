import Foundation
import Testing
import WebKit
@testable import CmuxNextPages

/// Same-origin storage oracle adapted from cmuxterm-hq-b7's PageHostPoolTests (4b04ad43).
@MainActor
struct PageStorageProbe {
    func write(_ host: PageWebView) async throws -> Bool {
        let result = try await host.webKitView.callAsyncJavaScript("""
        localStorage.setItem('pool-secret', 'secret');
        sessionStorage.setItem('pool-secret', 'secret');
        await new Promise((resolve, reject) => {
          const open = indexedDB.open('pool-secret-db', 1);
          open.onupgradeneeded = () => open.result.createObjectStore('secrets');
          open.onerror = () => reject(open.error);
          open.onsuccess = () => {
            const db = open.result;
            const tx = db.transaction('secrets', 'readwrite');
            tx.objectStore('secrets').put('secret', 'key');
            tx.oncomplete = () => { db.close(); resolve(); };
            tx.onerror = () => reject(tx.error);
          };
        });
        let cache = false;
        try {
          const store = await caches.open('pool-secret-cache');
          await store.put('/pool-secret', new Response('secret'));
          cache = true;
        } catch {}
        return cache;
        """, contentWorld: .page)
        return try #require(result as? Bool)
    }

    func expectEmpty(_ host: PageWebView, cacheWasAvailable: Bool) async throws {
        let result = try await host.webKitView.callAsyncJavaScript("""
        const indexed = await new Promise((resolve, reject) => {
          let fresh = false;
          const open = indexedDB.open('pool-secret-db');
          open.onupgradeneeded = (event) => { fresh = event.oldVersion === 0; };
          open.onerror = () => reject(open.error);
          open.onsuccess = () => {
            const db = open.result;
            const empty = fresh && !db.objectStoreNames.contains('secrets');
            db.close();
            resolve(empty);
          };
        });
        let cacheKeys = null;
        if (globalThis.caches) cacheKeys = await caches.keys();
        return JSON.stringify({
          local: localStorage.getItem('pool-secret'), session: sessionStorage.getItem('pool-secret'),
          indexed, cacheKeys
        });
        """, contentWorld: .page)
        let text = try #require(result as? String)
        let seen = try JSONDecoder().decode(Seen.self, from: Data(text.utf8))
        #expect(seen.local == nil)
        #expect(seen.session == nil)
        #expect(seen.indexed, "The reused host retained the previous page's IndexedDB")
        if cacheWasAvailable { #expect(seen.cacheKeys == []) }
    }

    private struct Seen: Decodable {
        var local: String?
        var session: String?
        var indexed: Bool
        var cacheKeys: [String]?
    }
}
