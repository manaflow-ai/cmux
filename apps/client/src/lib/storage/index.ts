export interface StorageAdapter {
  readonly id: string;
  getItem: (key: string) => string | null;
  setItem: (key: string, value: string) => void;
  removeItem: (key: string) => void;
}

class MemoryStorageAdapter implements StorageAdapter {
  readonly id = "memory";
  private readonly store = new Map<string, string>();

  getItem(key: string): string | null {
    return this.store.get(key) ?? null;
  }

  setItem(key: string, value: string): void {
    this.store.set(key, value);
  }

  removeItem(key: string): void {
    this.store.delete(key);
  }
}

class BrowserStorageAdapter implements StorageAdapter {
  readonly id = "browser";
  constructor(private readonly storage: Storage) {}

  getItem(key: string): string | null {
    try {
      return this.storage.getItem(key);
    } catch (error) {
      console.warn("Browser storage getItem failed", { key, error });
      return null;
    }
  }

  setItem(key: string, value: string): void {
    try {
      this.storage.setItem(key, value);
    } catch (error) {
      console.warn("Browser storage setItem failed", { key, error });
    }
  }

  removeItem(key: string): void {
    try {
      this.storage.removeItem(key);
    } catch (error) {
      console.warn("Browser storage removeItem failed", { key, error });
    }
  }
}

export interface RendererPersistentStorage {
  getItem: (key: string) => string | null;
  setItem: (key: string, value: string) => boolean;
  removeItem: (key: string) => boolean;
}

class ElectronStorageAdapter implements StorageAdapter {
  readonly id = "electron";
  constructor(
    private readonly storage: RendererPersistentStorage,
    private readonly fallback?: StorageAdapter
  ) {}

  getItem(key: string): string | null {
    try {
      const value = this.storage.getItem(key);
      if (value !== null && value !== undefined) {
        return value;
      }
    } catch (error) {
      console.warn("Electron storage getItem failed", { key, error });
    }

    if (this.fallback) {
      const legacyValue = this.fallback.getItem(key);
      if (legacyValue !== null && legacyValue !== undefined) {
        try {
          this.storage.setItem(key, legacyValue);
        } catch (error) {
          console.warn("Failed to backfill electron storage", { key, error });
        }
        return legacyValue;
      }
    }

    return null;
  }

  setItem(key: string, value: string): void {
    let success = false;
    try {
      success = Boolean(this.storage.setItem(key, value));
    } catch (error) {
      console.warn("Electron storage setItem failed", { key, error });
    }

    if (!success && this.fallback) {
      this.fallback.setItem(key, value);
    }
  }

  removeItem(key: string): void {
    let success = false;
    try {
      success = Boolean(this.storage.removeItem(key));
    } catch (error) {
      console.warn("Electron storage removeItem failed", { key, error });
    }

    if (!success && this.fallback) {
      this.fallback.removeItem(key);
    }
  }
}

function createDefaultAdapter(): StorageAdapter {
  if (typeof window === "undefined") {
    return new MemoryStorageAdapter();
  }

  const hasLocalStorage = (() => {
    try {
      return Boolean(window.localStorage);
    } catch {
      return false;
    }
  })();

  const fallback = hasLocalStorage
    ? new BrowserStorageAdapter(window.localStorage)
    : undefined;

  if (window.cmux?.storage) {
    return new ElectronStorageAdapter(window.cmux.storage, fallback);
  }

  if (fallback) {
    return fallback;
  }

  return new MemoryStorageAdapter();
}

let activeAdapter: StorageAdapter = createDefaultAdapter();

const listeners = new Set<(adapter: StorageAdapter) => void>();

export function setStorageAdapter(adapter: StorageAdapter): void {
  activeAdapter = adapter;
  listeners.forEach((listener) => listener(adapter));
}

export function getStorageAdapter(): StorageAdapter {
  return activeAdapter;
}

export function onStorageAdapterChange(
  listener: (adapter: StorageAdapter) => void
): () => void {
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
  };
}

export function createMemoryStorageAdapter(): StorageAdapter {
  return new MemoryStorageAdapter();
}

export function createBrowserStorageAdapter(storage: Storage): StorageAdapter {
  return new BrowserStorageAdapter(storage);
}

export function createElectronStorageAdapter(
  rendererStorage: RendererPersistentStorage,
  fallback?: StorageAdapter
): StorageAdapter {
  return new ElectronStorageAdapter(rendererStorage, fallback);
}

export const storage = {
  getItem(key: string): string | null {
    return activeAdapter.getItem(key);
  },
  setItem(key: string, value: string): void {
    activeAdapter.setItem(key, value);
  },
  removeItem(key: string): void {
    activeAdapter.removeItem(key);
  },
};
