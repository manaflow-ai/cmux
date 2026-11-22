/**
 * A Durable Object stub seen through its class's own method signatures. Method names and arguments are
 * checked against the class, and results keep the types the class declares (a call over RPC always
 * returns a promise). workers-types' RPC typing turns a result that holds `unknown` (ReadResult.value,
 * OwnerFrame) into `never` and adds `Disposable` to each union member, so call sites that read such
 * results use this view of the same stub.
 */
export type DeclaredStub<T> = {
  readonly [K in keyof T as T[K] extends (...args: never[]) => unknown ? K : never]: T[K] extends (...args: infer A) => infer R ? (...args: A) => Promise<Awaited<R>> : never
}

export const declared = <T extends Rpc.DurableObjectBranded>(stub: DurableObjectStub<T>): DeclaredStub<T> => stub as unknown as DeclaredStub<T>
