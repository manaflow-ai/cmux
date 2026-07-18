package com.cmux;

public sealed interface TopologySubscribeOutcome permits TopologySubscription, TopologyResnapshotRequired {}
