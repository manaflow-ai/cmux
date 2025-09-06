interface CmuxSocketAPI {
  connect: (query: Record<string, string>) => Promise<{ socketId: string; connected: boolean }>;
  disconnect: (socketId: string) => Promise<{ disconnected: boolean }>;
  emit: (socketId: string, eventName: string, ...args: unknown[]) => Promise<{ success: boolean }>;
  on: (socketId: string, eventName: string) => Promise<{ success: boolean }>;
  onEvent: (socketId: string, callback: (eventName: string, ...args: unknown[]) => void) => void;
}

interface CmuxAPI {
  register: (meta: { auth?: string; team?: string; auth_json?: string }) => Promise<unknown>;
  rpc: (event: string, ...args: unknown[]) => Promise<unknown>;
  on: (event: string, callback: (...args: unknown[]) => void) => () => void;
  off: (event: string, callback?: (...args: unknown[]) => void) => void;
  socket: CmuxSocketAPI;
}

declare global {
  interface Window {
    cmux: CmuxAPI;
  }
}

export {};