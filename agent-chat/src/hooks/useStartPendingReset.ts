import { useEffect, type Dispatch, type SetStateAction } from "react";

export function useStartPendingReset(error: string, connectionEpoch: number, setStarting: Dispatch<SetStateAction<boolean>>) {
  useEffect(() => {
    if (error) setStarting(false);
  }, [error, setStarting]);
  useEffect(() => {
    setStarting(false);
  }, [connectionEpoch, setStarting]);
}
