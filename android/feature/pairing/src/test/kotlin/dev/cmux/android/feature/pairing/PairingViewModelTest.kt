package dev.cmux.android.feature.pairing

import dev.cmux.android.core.auth.StackAuthTokenStore
import dev.cmux.android.core.pairing.*
import io.mockk.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.test.*
import org.junit.jupiter.api.Assertions.*
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test

/**
 * Unit tests for PairingViewModel state machine.
 *
 * Network calls are replaced with mocked dependencies so tests run on JVM.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class PairingViewModelTest {

    private val pairedMacStore = mockk<PairedMacStore>(relaxed = true)
    private val tokenStore = mockk<StackAuthTokenStore>(relaxed = true)
    private val testDispatcher = StandardTestDispatcher()

    @BeforeEach
    fun setUp() {
        Dispatchers.setMain(testDispatcher)
    }

    @Test
    fun `initial state is Idle`() = runTest {
        val vm = PairingViewModel(pairedMacStore, tokenStore)
        assertEquals(PairingState.Idle, vm.state.value)
    }

    @Test
    fun `startScanning transitions to Scanning`() = runTest {
        val vm = PairingViewModel(pairedMacStore, tokenStore)
        vm.startScanning()
        assertEquals(PairingState.Scanning, vm.state.value)
    }

    @Test
    fun `invalid QR URL transitions to Error`() = runTest {
        val vm = PairingViewModel(pairedMacStore, tokenStore)
        vm.startScanning()
        vm.onQrCodeScanned("https://not-a-cmux-url.com")
        testDispatcher.scheduler.advanceUntilIdle()
        val state = vm.state.value
        assertTrue(state is PairingState.Error, "Expected Error but got $state")
    }

    @Test
    fun `reset from Error returns to Idle`() = runTest {
        val vm = PairingViewModel(pairedMacStore, tokenStore)
        vm.startScanning()
        vm.onQrCodeScanned("invalid")
        testDispatcher.scheduler.advanceUntilIdle()
        assertTrue(vm.state.value is PairingState.Error)
        vm.reset()
        assertEquals(PairingState.Idle, vm.state.value)
    }

    @Test
    fun `onQrCodeScanned with loopback route sets Error state`() = runTest {
        val vm = PairingViewModel(pairedMacStore, tokenStore)
        vm.startScanning()
        // Loopback route should be rejected at decoder level
        val url = "cmux-ios://attach?v=2&r=127.0.0.1:58465"
        vm.onQrCodeScanned(url)
        testDispatcher.scheduler.advanceUntilIdle()
        assertTrue(vm.state.value is PairingState.Error)
    }

    @Test
    fun `DecodeError maps to Error state`() = runTest {
        val vm = PairingViewModel(pairedMacStore, tokenStore)
        // Unsupported QR version
        vm.onQrCodeScanned("cmux-ios://attach?v=999&r=100.64.1.2:58465")
        testDispatcher.scheduler.advanceUntilIdle()
        assertTrue(vm.state.value is PairingState.Error)
    }
}
